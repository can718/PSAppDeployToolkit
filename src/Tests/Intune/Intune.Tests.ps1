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

function Get-IntuneTestApps
{
    $apps = @(& (Join-Path $PSScriptRoot '..\_Shared\TestApps.ps1'))

    $includeNames = @($env:PSADT_INTUNE_INCLUDE_APP_NAMES -split ';' | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })
    if ($includeNames.Count -gt 0)
    {
        $apps = @($apps | Where-Object { $includeNames -contains $_.Name })
    }

    $excludeNames = @($env:PSADT_INTUNE_EXCLUDE_APP_NAMES -split ';' | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })
    if ($excludeNames.Count -gt 0)
    {
        $apps = @($apps | Where-Object { $excludeNames -notcontains $_.Name })
    }

    return $apps
}

BeforeAll {
    # Resolve script root for relative paths.
    $script:_tfScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }

    # Load shared helper functions.
    . (Join-Path $script:_tfScriptRoot 'IntuneTestHelpers.ps1')

    $script:TestCaseMapHelpersPath = Join-Path $script:_tfScriptRoot '..\_Shared\TestCaseMap.Helpers.ps1'
    if (-not (Test-Path -LiteralPath $script:TestCaseMapHelpersPath -PathType Leaf))
    {
        throw "Required test case map helper file not found: $script:TestCaseMapHelpersPath"
    }
    . $script:TestCaseMapHelpersPath
    $script:TFTestCaseIdMap = Import-PSADTTestCaseIdMap -ScriptRoot $script:_tfScriptRoot

    $script:SharedEnvironmentHelpersPath = Join-Path $script:_tfScriptRoot '..\_Shared\TestAppEnvironment.Helpers.ps1'
    if (-not (Test-Path -LiteralPath $script:SharedEnvironmentHelpersPath -PathType Leaf))
    {
        throw "Required shared helper file not found: $script:SharedEnvironmentHelpersPath"
    }
    . $script:SharedEnvironmentHelpersPath

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
            -ClientSecret $script:ClientSecret `
            -ExistingGroupId $env:PSADT_INTUNE_TEST_GROUP_ID
        $script:GroupID = $groupResult.GroupId
        if ($script:GroupID)
        {
            $env:PSADT_INTUNE_TEST_GROUP_ID = $script:GroupID
        }

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
        $script:CurrentTestCaseId = Resolve-PSADTTestCaseId -TestCaseIdMap $script:TFTestCaseIdMap -TestMethod $script:CurrentTestMethod
        $script:TFCurrentResultId = Invoke-TFReportTestCase `
            -TFState   $script:TFState `
            -TestClass $script:CurrentTestClass `
            -TestMethod $script:CurrentTestMethod `
            -TestCaseId $script:CurrentTestCaseId

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
        # Body-level assignment executes during Pester Discovery (needed for -ForEach).
        $parallelAppsForEach = @(Get-IntuneTestApps)
        $env:PSADT_INTUNE_PARALLEL_APP_NAMES_FOR_PESTER = ConvertTo-Json -InputObject @($parallelAppsForEach | ForEach-Object { $_.Name }) -Compress

        BeforeAll {
            # Rehydrate during Run phase to guarantee availability in It blocks.
            # Pester 6 isolates Discovery-time local variables from the Run phase.
            $parallelAppNamesForRun = @($env:PSADT_INTUNE_PARALLEL_APP_NAMES_FOR_PESTER | ConvertFrom-Json)
            # Top-level test-file functions belong to Pester's discovery scope and are not
            # reliably available from nested run blocks in Pester 6.
            $availableAppsForRun = @(& (Join-Path $script:_tfScriptRoot '..\_Shared\TestApps.ps1'))
            $script:ParallelApps = @(
                foreach ($appName in $parallelAppNamesForRun)
                {
                    $availableAppsForRun | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
                }
            )
            $script:ParallelInstallResults = @{}
            $script:SkippedParallelInstallOutcomeReasons = @{}
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
                    WorkDir              = $env.WorkDir
                    IntuneWinAppUtilPath = $script:IntuneWinAppUtil
                }
                $effectiveSetupFileName = if ($app.SetupFileName)
                {
                    $app.SetupFileName
                }
                elseif ($app.TemplateVersion -eq 'V3')
                {
                    'Deploy-Application.exe'
                }
                else
                {
                    $null
                }
                if ($effectiveSetupFileName) { $packageParams.SetupFileName = $effectiveSetupFileName }
                $package = New-IntuneWinPackage @packageParams
                $package.IntuneWinPath | Should -Not -BeNullOrEmpty

                # Build detection rule (unified signature: all builders accept $FilesDir).
                $DetectionRule = & $app.DetectionRuleBuilder $env.FilesDir

                # Upload to Intune.
                $intuneDisplayName = '{0}-{1}' -f $package.DisplayName, $script:IntuneDisplayNameSuffix
                Write-Information "[Intune Upload] Uploading $($app.TemplateVersion) app '$intuneDisplayName'..." -InformationAction Continue
                $publishParams = @{
                    FilePath      = $package.IntuneWinPath
                    DisplayName   = $intuneDisplayName
                    DetectionRule = $DetectionRule
                }
                $effectiveInstallCmd = if ($app.InstallCmd)
                {
                    $app.InstallCmd
                }
                elseif ($app.TemplateVersion -eq 'V3')
                {
                    "Deploy-Application.exe -DeploymentType 'Install'"
                }
                else
                {
                    $null
                }
                $effectiveUninstallCmd = if ($app.UninstallCmd)
                {
                    $app.UninstallCmd
                }
                elseif ($app.TemplateVersion -eq 'V3')
                {
                    "Deploy-Application.exe -DeploymentType 'Uninstall'"
                }
                else
                {
                    $null
                }

                if ($effectiveInstallCmd) { $publishParams.InstallCmd = $effectiveInstallCmd }
                if ($effectiveUninstallCmd) { $publishParams.UninstallCmd = $effectiveUninstallCmd }
                $win32App = Publish-IntuneWin32App @publishParams
                $win32App | Should -Not -BeNullOrEmpty

                # Assign to test group.
                Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID `
                    -Intent 'required' -Notification 'showAll' -Verbose

                $script:UploadedApps[$app.Name] = @{
                    Win32AppId      = $win32App.id
                    DisplayName     = $intuneDisplayName
                    RegDisplayName  = if ($app.RegDisplayName) { $app.RegDisplayName } else { $app.Name }
                    RegVersionValue = if ($app.RegVersionValue) { $app.RegVersionValue } else { $app.AppVersion }
                    RegVersionName  = if ($app.RegVersionName) { $app.RegVersionName } else { 'DisplayVersion' }
                }
                Write-Information "[$($app.Name)] Uploaded and assigned successfully." -InformationAction Continue
            }

            $script:UploadedApps.Count | Should -Be $script:ParallelApps.Count
        }

        It '[INTUNE:InstallSync] MDM sync, then parallel poll for expected install outcomes' {
            $script:UploadedApps | Should -Not -BeNullOrEmpty -Because 'Upload step must succeed first'

            $notepadApp = $script:ParallelApps | Where-Object { $_.Name -eq 'Notepad++' } | Select-Object -First 1
            if ($notepadApp)
            {
                $notepadExePath = 'C:\Program Files (x86)\Notepad++\notepad++.exe'
                $interactiveSessionId = Get-IntuneActiveInteractiveSessionId -LogPrefix 'Notepad++'
                if ($null -eq $interactiveSessionId)
                {
                    $interactiveSessionId = 0
                }
                $notepadLaunchSucceeded = Start-IntuneSystemProcess `
                    -FilePath $notepadExePath `
                    -ProcessName 'notepad++' `
                    -InteractiveSessionId $interactiveSessionId `
                    -LogPrefix 'Notepad++' `
                    -StopExistingProcess `
                    -PassThru
                if (-not $notepadLaunchSucceeded)
                {
                    $script:SkippedParallelInstallOutcomeReasons['Notepad++'] = "Notepad++ deferral precondition was not established because PsExec could not start '$notepadExePath' as SYSTEM."
                }
            }

            Invoke-MdmSync
            Start-Sleep -Seconds 8
            Wait-IntuneManagementExtension

            $expectedDeferralAppNames = @(
                $script:ParallelApps |
                    Where-Object { $_.TemplateVersion -eq 'V4' -and (Get-PsadtForceCountdownDeferralExpectation -App $_).Expected } |
                    Where-Object { -not $script:SkippedParallelInstallOutcomeReasons.ContainsKey($_.Name) } |
                    ForEach-Object { $_.Name }
            )
            $appsForRegistryPoll = @(
                $script:UploadedApps.Keys |
                    Where-Object { $expectedDeferralAppNames -notcontains $_ }
            )

            $helperPath = Join-Path $PSScriptRoot 'IntuneTestHelpers.ps1'
            $result = @{ Succeeded = @(); Failed = @() }
            if ($appsForRegistryPoll.Count -gt 0)
            {
                $result = Invoke-ParallelAppPollWithRetry `
                    -UploadedApps    $script:UploadedApps `
                    -Operation       'Install' `
                    -HelperScriptPath $helperPath `
                    -AppNames        $appsForRegistryPoll
            }

            $expectedDeferralApps = @(
                $script:ParallelApps |
                    Where-Object { $expectedDeferralAppNames -contains $_.Name }
            )
            if ($expectedDeferralApps.Count -gt 0)
            {
                Write-Information "[Parallel Install] Triggering expected deferral app install once: $($expectedDeferralAppNames -join ', ')" -InformationAction Continue
                Invoke-MdmSync
                Start-Sleep -Seconds 8
                Wait-IntuneManagementExtension

                foreach ($appConfig in $expectedDeferralApps)
                {
                    $null = Wait-PsadtForceCountdownDeferralLog -App $appConfig
                }
            }

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

        It '[INTUNE:<Name>_Install][<TemplateVersion>] <Name> should reach expected install outcome' -ForEach $parallelAppsForEach {
            $failures = @()
            $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
            $expectForceCountdownDeferral = $false
            $expectInstallFailure = $Name -eq 'Notepad++'

            if ($script:SkippedParallelInstallOutcomeReasons.ContainsKey($Name))
            {
                Set-ItResult -Skipped -Because $script:SkippedParallelInstallOutcomeReasons[$Name]
                return
            }

            if ($appConfig -and $appConfig.TemplateVersion -eq 'V4')
            {
                $expectForceCountdownDeferral = (Get-PsadtForceCountdownDeferralExpectation -App $appConfig).Expected
            }

            if ($expectForceCountdownDeferral)
            {
                if ($script:ParallelInstallResults[$Name])
                {
                    $failures += '[Install Status] app installed successfully, but ForceCountdown deferral was expected'
                }

                if ($appConfig)
                {
                    $logValidation = Test-PsadtForceCountdownDeferralLog -App $appConfig -DeploymentType 'Install'
                    if (-not $logValidation.Success)
                    {
                        $failures += "[Log Validation] $($logValidation.Message)"
                    }

                    $versionValidation = Test-PsadtAppFileVersion -App $appConfig -ExpectedState 'Deferral'
                    if (-not $versionValidation.Success)
                    {
                        $failures += "[Version Validation] $($versionValidation.Message)"
                    }
                }
            }
            elseif ($expectInstallFailure)
            {
                if ($script:ParallelInstallResults[$Name])
                {
                    $failures += '[Install Status] app installed successfully, but install failure was expected'
                }

                if ($appConfig)
                {
                    $logValidation = Test-PsadtInstallFailureLog -App $appConfig -DeploymentType 'Install'
                    if (-not $logValidation.Success)
                    {
                        $failures += "[Log Validation] $($logValidation.Message)"
                    }

                    $versionValidation = Test-PsadtAppFileVersion -App $appConfig -ExpectedState 'Deferral'
                    if (-not $versionValidation.Success)
                    {
                        $failures += "[Version Validation] $($versionValidation.Message)"
                    }
                }
            }
            elseif (-not $script:ParallelInstallResults[$Name])
            {
                $failures += '[Install Status] app was not installed successfully via Intune MDM sync'
            }

            if ($appConfig -and -not $expectForceCountdownDeferral -and -not $expectInstallFailure)
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
            # Build uninstall candidate list from installed apps, honoring per-app filters.
            $appsForUninstall = @()
            foreach ($appName in $script:ParallelInstallResults.Keys)
            {
                $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
                if ($appConfig -and $appConfig.SkipUninstall)
                {
                    Write-Information "[Parallel Uninstall] Skipping uninstall for '$appName' due to SkipUninstall filter." -InformationAction Continue
                }
                else
                {
                    $appsForUninstall += $appName
                }
            }

            if (-not $appsForUninstall)
            {
                Set-ItResult -Skipped -Because 'No installed apps are eligible for uninstall testing.'
                return
            }

            # Reassign all apps with uninstall intent.
            foreach ($appName in $appsForUninstall)
            {
                $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
                if ($appConfig -and $appConfig.PreUninstallScript)
                {
                    & $appConfig.PreUninstallScript
                }

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

        It '[INTUNE:<Name>_Uninstall][<TemplateVersion>] <Name> should be uninstalled' -ForEach ($parallelAppsForEach | Where-Object { -not $_.SkipUninstall }) -AllowNullOrEmptyForEach {
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

            # Clean up Azure AD test group only after the final split Intune run.
            $cleanupGroup = $env:PSADT_INTUNE_CLEANUP_GROUP -ne 'false'
            if ($script:GroupID -and $cleanupGroup)
            {
                Write-Information "Cleaning up Azure AD test group..." -InformationAction Continue
                try
                {
                    Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$($script:GroupID)" -ErrorAction Stop
                    Start-Sleep -Seconds 5
                    Remove-Item Env:\PSADT_INTUNE_TEST_GROUP_ID -ErrorAction SilentlyContinue
                }
                catch
                {
                    Write-Warning "[Intune] Failed to clean up Azure AD test group '$($script:GroupID)': $($_.Exception.Message)"
                }
            }
            elseif ($script:GroupID)
            {
                Write-Information "Keeping Azure AD test group '$script:GroupID' for the next Intune test split." -InformationAction Continue
            }

            Remove-Item Env:\PSADT_INTUNE_PARALLEL_APP_NAMES_FOR_PESTER -ErrorAction SilentlyContinue
        }
    }
}

#pragma warning restore PSPlaceOpenBrace
