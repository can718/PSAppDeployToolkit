#pragma warning disable PSPlaceOpenBrace
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '')]
param()

# ---------------------------------------------------------------------------
# Intune Win32 App Integration Tests
#
# Test lifecycle:
#   1. Global BeforeAll   - load helpers, TerraForge reporting, IntuneWin32App module
#   2. Context BeforeAll  - create Azure AD test group, resolve IntuneWinAppUtil
#   3. Per-test BeforeEach - TerraForge reporting, Intune Graph auth, skip guard
#   4. It block           - prepare -> wrap -> upload -> assign -> sync -> verify
#   5. Per-test AfterEach - TerraForge result update
# ---------------------------------------------------------------------------

BeforeAll {
    # Resolve script root for relative paths.
    $script:_tfScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }

    # Load shared helper functions.
    . (Join-Path $script:_tfScriptRoot 'IntuneTestHelpers.ps1')

    # Load TerraForge helper script at script scope so exported functions
    # remain available in later Pester blocks (BeforeEach/AfterEach).
    $script:TerraForgeHelperPath = [System.IO.Path]::GetFullPath((Join-Path $script:_tfScriptRoot '..\..\..\.github\scripts\TerraForge-AgentHelper.ps1'))
    if (Test-Path $script:TerraForgeHelperPath)
    {
        . $script:TerraForgeHelperPath
    }
    else
    {
        Write-Warning "[TerraForge] Helper script not found at: $script:TerraForgeHelperPath"
    }

    Write-Information "[Pester] Version: $((Get-Module Pester).Version)" -InformationAction Continue

    # ---------------------------------------------------------------------------
    # Initialize TerraForge reporting (no-op when env vars are not set).
    # ---------------------------------------------------------------------------
    $script:TFState = Initialize-TerraForgeReporting -ScriptRoot $script:_tfScriptRoot

    # ---------------------------------------------------------------------------
    # Store credentials from environment for Intune Graph authentication.
    # ---------------------------------------------------------------------------
    $script:TenantID = $env:TEST_TENANTID
    $script:ClientID = $env:TEST_CLIENTID
    $script:ClientSecret = $env:TEST_CLIENTSECRET

    # ---------------------------------------------------------------------------
    # Ensure IntuneWin32App module is available.
    # ---------------------------------------------------------------------------
    if (-not (Get-Module -Name 'IntuneWin32App' -ListAvailable))
    {
        Install-Module -Name 'IntuneWin32App' -AcceptLicense -Force -Scope CurrentUser
    }
    Import-Module -Name 'IntuneWin32App' -ErrorAction Stop
}

Describe 'Intune Tests' {
    BeforeAll {
        # Prepare a clean workspace root.
        $script:BasePath = 'C:\PSADT'
        if (Test-Path $script:BasePath)
        {
            Remove-Item -Path $script:BasePath -Recurse -Force
        }
        New-Item -Path $script:BasePath -ItemType Directory -Force | Out-Null

        # Ensure uploaded app names are unique per machine for parallel test runs.
        $script:IntuneDisplayNameSuffix = if ([System.String]::IsNullOrWhiteSpace($env:COMPUTERNAME))
        {
            'UnknownHost'
        }
        else
        {
            $env:COMPUTERNAME
        }

        # Resolve IntuneWinAppUtil.exe.
        $script:IntuneWinAppUtil = Get-IntuneWinAppUtilPath
        $script:Win32WrapAndUploadSkipReason = if (-not $script:IntuneWinAppUtil)
        {
            'IntuneWinAppUtil.exe not found at C:\Tools\Intune\IntuneWinAppUtil.exe'
        }
        else
        {
            $null
        }

        # Create Azure AD test group and add the current device.
        $groupResult = Initialize-IntuneTestGroup `
            -TenantId     $script:TenantID `
            -ClientId     $script:ClientID `
            -ClientSecret $script:ClientSecret
        $script:GroupID = $groupResult.GroupId

        if ($groupResult.SkipReason)
        {
            $script:Win32WrapAndUploadSkipReason = if ($script:Win32WrapAndUploadSkipReason)
            {
                "$($script:Win32WrapAndUploadSkipReason); $($groupResult.SkipReason)"
            }
            else
            {
                $groupResult.SkipReason
            }
        }
    }

    BeforeEach {
        # TerraForge: create a result entry for this test.
        $testInfo = $____Pester.CurrentTest
        $script:CurrentTestClass = 'Intune Tests / Win32 App Wrap and Upload'
        $script:CurrentTestMethod = $testInfo.Name
        $script:TFCurrentResultId = Invoke-TFReportTestCase `
            -TFState   $script:TFState `
            -TestClass $script:CurrentTestClass `
            -TestMethod $script:CurrentTestMethod

        # Ensure Intune Graph session is active.
        if ($(Test-AccessToken) -eq $false)
        {
            Write-Information "Connecting to MS Intune Graph..."
            Connect-MSIntuneGraph -TenantID $script:TenantID -ClientID $script:ClientID -ClientSecret $script:ClientSecret
        }

        # Skip guard: skip the entire test if prerequisites are missing.
        if ($script:Win32WrapAndUploadSkipReason)
        {
            Set-ItResult -Skipped -Because $script:Win32WrapAndUploadSkipReason
        }
    }

    AfterEach {
        Invoke-TFUpdateTestCase `
            -TFState    $script:TFState `
            -ResultId   $script:TFCurrentResultId `
            -TestResult $____Pester.CurrentTest

        # Clean up any test artifacts from the client registry to ensure a clean slate for the next test.
        Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\IntuneManagementExtension" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 10 # brief pause to ensure registry changes are committed before the next test starts
    }

    Context 'Parallel Install - V3,V4 - Batch Upload, Single Sync, Parallel Poll install and uninstall of multiple apps' {
        # Define all apps to install in parallel.
        # Body-level assignment executes during Pester 5 Discovery (needed for -ForEach).
        $script:ParallelApps = & (Join-Path $PSScriptRoot 'IntuneTestApps.ps1')

        BeforeAll {
            # Re-assign during Run phase to guarantee availability in It blocks.
            # Pester 5 may isolate Discovery-time $script: variables from the Run phase.
            $script:ParallelApps = & (Join-Path $PSScriptRoot 'IntuneTestApps.ps1')
            $script:ParallelInstallResults = @{}
        }

        It '[INTUNE:BatchUpload] Batch upload all apps and assign to group' {
            $script:UploadedApps = @{}

            foreach ($app in $script:ParallelApps)
            {
                Write-Information "--- Processing $($app.Name) ---" -InformationAction Continue

                # Run pre-install script if defined (e.g., install lower version for upgrade).
                if ($app.PreInstallScript)
                {
                    & $app.PreInstallScript
                }

                # Prepare working directory (dispatches to V3/V4 internally).
                $env = New-IntuneTestWorkDir -App $app -BasePath $script:BasePath

                # Wrap into .intunewin package.
                $packageParams = @{
                    WorkDir = $env.WorkDir
                    IntuneWinAppUtilPath = $script:IntuneWinAppUtil
                }
                if ($app.SetupFileName) { $packageParams.SetupFileName = $app.SetupFileName }
                $package = New-IntuneWinPackage @packageParams
                $package.IntuneWinPath | Should -Not -BeNullOrEmpty

                # Build detection rule (unified signature: all builders accept $FilesDir).
                $DetectionRule = & $app.DetectionRuleBuilder $env.FilesDir

                # Upload to Intune.
                $intuneDisplayName = '{0}-{1}' -f $package.DisplayName, $script:IntuneDisplayNameSuffix
                Write-Information "[Intune Upload] Uploading $($app.TemplateVersion) app '$intuneDisplayName'..." -InformationAction Continue
                $publishParams = @{
                    FilePath = $package.IntuneWinPath
                    DisplayName = $intuneDisplayName
                    DetectionRule = $DetectionRule
                }
                if ($app.InstallCmd) { $publishParams.InstallCmd = $app.InstallCmd }
                if ($app.UninstallCmd) { $publishParams.UninstallCmd = $app.UninstallCmd }
                $win32App = Publish-IntuneWin32App @publishParams
                $win32App | Should -Not -BeNullOrEmpty

                # Assign to test group.
                Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID `
                    -Intent 'required' -Notification 'showAll' -Verbose

                $script:UploadedApps[$app.Name] = @{
                    Win32AppId = $win32App.id
                    DisplayName = $intuneDisplayName
                    RegDisplayName = $app.RegDisplayName
                    RegVersionValue = $app.RegVersionValue
                    RegVersionName = $app.RegVersionName
                }
                Write-Information "[$($app.Name)] Uploaded and assigned successfully." -InformationAction Continue
            }

            $script:UploadedApps.Count | Should -Be $script:ParallelApps.Count
        }

        It '[INTUNE:InstallSync] MDM sync, then parallel poll for all installations' {
            $script:UploadedApps | Should -Not -BeNullOrEmpty -Because 'Upload step must succeed first'

            Invoke-MdmSync
            Start-Sleep -Seconds 8
            Wait-IntuneManagementExtension

            $helperPath = Join-Path $PSScriptRoot 'IntuneTestHelpers.ps1'
            $result = Invoke-ParallelAppPollWithRetry `
                -UploadedApps    $script:UploadedApps `
                -Operation       'Install' `
                -HelperScriptPath $helperPath

            # Store results and run post-install scripts for succeeded apps.
            foreach ($appName in $result.Succeeded)
            {
                $script:ParallelInstallResults[$appName] = $true

                $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
                if ($appConfig -and $appConfig.PostInstallScript)
                {
                    & $appConfig.PostInstallScript
                }
            }
        }

        It '[INTUNE:<Name>_Install][TemplateVersion] <Name> should be installed' -ForEach $script:ParallelApps {
            $failures = @()

            if (-not $script:ParallelInstallResults[$Name])
            {
                $failures += '[Install Status] app was not installed successfully via Intune MDM sync'
            }

            $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
            if ($appConfig)
            {
                $logValidation = Invoke-PsadtLogValidation -App $appConfig -DeploymentType 'Install'
                if (-not $logValidation.Success)
                {
                    $failures += "[Log Validation] $($logValidation.Message)"
                }
            }

            $failures | Should -BeNullOrEmpty -Because "'$Name' failed: $($failures -join '; ')"
        }

        It '[INTUNE:UninstallSync] Reassign uninstall intent, MDM sync, then parallel poll for all uninstallations' {
            $script:ParallelInstallResults.Count | Should -BeGreaterThan 0 -Because 'At least one app must have installed'

            # Build uninstall candidate list from installed apps, honoring per-app filters.
            $appsForUninstall = @()
            foreach ($appName in $script:ParallelInstallResults.Keys)
            {
                $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
                if ($appConfig -and $appConfig.SkipUninstall)
                {
                    Write-Information "[Parallel Uninstall] Skipping uninstall for '$appName' due to SkipUninstall filter." -InformationAction Continue
                    continue
                }

                $appsForUninstall += $appName
            }

            if (-not $appsForUninstall)
            {
                Set-ItResult -Skipped -Because 'All installed apps are filtered out from uninstall test by SkipUninstall.'
            }

            # Reassign all apps with uninstall intent.
            foreach ($appName in $appsForUninstall)
            {
                $appInfo = $script:UploadedApps[$appName]
                Remove-IntuneWin32AppAssignmentGroup -ID $appInfo.Win32AppId -GroupID $script:GroupID
                Add-IntuneWin32AppAssignmentGroup -Include -ID $appInfo.Win32AppId -GroupID $script:GroupID `
                    -Intent 'uninstall' -Notification 'showAll' -Verbose
            }

            Invoke-MdmSync
            Start-Sleep -Seconds 8
            Wait-IntuneManagementExtension

            $helperPath = Join-Path $PSScriptRoot 'IntuneTestHelpers.ps1'
            $result = Invoke-ParallelAppPollWithRetry `
                -UploadedApps    $script:UploadedApps `
                -Operation       'Uninstall' `
                -HelperScriptPath $helperPath `
                -AppNames        $appsForUninstall

            # Store results for per-app assertion in subsequent It blocks.
            $script:ParallelUninstallResults = @{}
            foreach ($app in $result.Succeeded)
            {
                $script:ParallelUninstallResults[$app] = $true
            }
        }

        It '[INTUNE:<Name>_Uninstall][TemplateVersion] <Name> should be uninstalled' -ForEach ($script:ParallelApps | Where-Object { -not $_.SkipUninstall }) {
            $failures = @()

            if (-not $script:ParallelUninstallResults[$Name])
            {
                $failures += '[Uninstall Status] app was not uninstalled successfully via Intune MDM sync'
            }

            $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
            if ($appConfig)
            {
                $logValidation = Invoke-PsadtLogValidation -App $appConfig -DeploymentType 'Uninstall'
                if (-not $logValidation.Success)
                {
                    $failures += "[Log Validation] $($logValidation.Message)"
                }
            }

            $failures | Should -BeNullOrEmpty -Because "'$Name' failed: $($failures -join '; ')"
        }

        AfterAll {
            # Clean up all uploaded Intune apps.
            if ($script:UploadedApps)
            {
                foreach ($appName in $script:UploadedApps.Keys)
                {
                    $appInfo = $script:UploadedApps[$appName]
                    Write-Information "Cleaning up Intune Win32 app '$($appInfo.DisplayName)'..." -InformationAction Continue
                    Remove-IntuneWin32App -ID $appInfo.Win32AppId -ErrorAction SilentlyContinue -Verbose
                }
            }

            # Clean up Azure AD test group.
            Write-Information "Cleaning up Azure AD test group..." -InformationAction Continue
            if ($script:GroupID)
            {
                Remove-MgGroup -GroupId $script:GroupID -ErrorAction Stop
                Start-Sleep -Seconds 5
            }
        }
    }
}

#pragma warning restore PSPlaceOpenBrace
