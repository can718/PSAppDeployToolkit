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
    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
    Write-Information "[Intune Debug] Get-IntuneTestApps initial count=$($apps.Count); Include='$env:PSADT_INTUNE_INCLUDE_APP_NAMES'; Exclude='$env:PSADT_INTUNE_EXCLUDE_APP_NAMES'." -InformationAction Continue

    $includeNames = @($env:PSADT_INTUNE_INCLUDE_APP_NAMES -split ';' | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })
    if ($includeNames.Count -gt 0)
    {
        # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
        Write-Information "[Intune Debug] Applying include filter: '$($includeNames -join ', ')'." -InformationAction Continue
        $apps = @($apps | Where-Object { $includeNames -contains $_.Name })
    }

    $excludeNames = @($env:PSADT_INTUNE_EXCLUDE_APP_NAMES -split ';' | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })
    if ($excludeNames.Count -gt 0)
    {
        # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
        Write-Information "[Intune Debug] Applying exclude filter: '$($excludeNames -join ', ')'." -InformationAction Continue
        $apps = @($apps | Where-Object { $excludeNames -notcontains $_.Name })
    }

    $appNames = @($apps | ForEach-Object { if ($_ -is [hashtable]) { $_['Name'] } else { $_.Name } })
    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
    Write-Information "[Intune Debug] Get-IntuneTestApps final count=$($apps.Count); Apps='$($appNames -join ', ')'." -InformationAction Continue

    return $apps
}

BeforeAll {
    # Resolve script root for relative paths.
    $script:_tfScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }

    # Load shared helper functions.
    . (Join-Path $script:_tfScriptRoot 'IntuneTestHelpers.ps1')

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

        $debugAppNames = @($script:ParallelApps | ForEach-Object { if ($_ -is [hashtable]) { $_['Name'] } else { $_.Name } })
        $debugAppTypes = @($script:ParallelApps | ForEach-Object { if ($null -eq $_) { '<null>' } else { $_.GetType().FullName } })
        # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
        Write-Information "[Intune Debug] Context BeforeAll complete. Include='$env:PSADT_INTUNE_INCLUDE_APP_NAMES'; Exclude='$env:PSADT_INTUNE_EXCLUDE_APP_NAMES'; GroupID='$script:GroupID'; SkipReason='$script:Win32WrapAndUploadSkipReason'; AppCount=$((@($script:ParallelApps)).Count); Apps='$($debugAppNames -join ', ')'; AppTypes='$($debugAppTypes -join ', ')'." -InformationAction Continue
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
        $script:ParallelApps = Get-IntuneTestApps

        BeforeAll {
            # Re-assign during Run phase to guarantee availability in It blocks.
            # Pester 5 may isolate Discovery-time $script: variables from the Run phase.
            $script:ParallelApps = Get-IntuneTestApps
            $script:ParallelInstallResults = @{}
        }

        It '[INTUNE:BatchUpload] Batch upload all apps and assign to group' {
            $script:UploadedApps = @{}
            $debugAppNames = @($script:ParallelApps | ForEach-Object { if ($_ -is [hashtable]) { $_['Name'] } else { $_.Name } })
            $debugAppTypes = @($script:ParallelApps | ForEach-Object { if ($null -eq $_) { '<null>' } else { $_.GetType().FullName } })
            # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
            Write-Information "[Intune Debug] BatchUpload started. Include='$env:PSADT_INTUNE_INCLUDE_APP_NAMES'; Exclude='$env:PSADT_INTUNE_EXCLUDE_APP_NAMES'; GroupID='$script:GroupID'; IntuneWinAppUtil='$script:IntuneWinAppUtil'; AppCount=$((@($script:ParallelApps)).Count); Apps='$($debugAppNames -join ', ')'; AppTypes='$($debugAppTypes -join ', ')'." -InformationAction Continue

            try
            {

            foreach ($app in $script:ParallelApps)
            {
                Write-Information "--- Processing $($app.Name) ---" -InformationAction Continue
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] BatchUpload app start. Name='$($app.Name)'; TemplateVersion='$($app.TemplateVersion)'; AppFolderName='$($app.AppFolderName)'; SkipUninstall='$($app.SkipUninstall)'." -InformationAction Continue

                # Run pre-install script if defined (e.g., install lower version for upgrade).
                if ($app.PreInstallScript)
                {
                    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                    Write-Information "[Intune Debug] Running PreInstallScript for '$($app.Name)'." -InformationAction Continue
                    & $app.PreInstallScript
                    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                    Write-Information "[Intune Debug] Completed PreInstallScript for '$($app.Name)'." -InformationAction Continue
                }

                # Prepare working directory (dispatches to V3/V4 internally).
                $env = New-IntuneTestWorkDir -App $app -BasePath $script:BasePath
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] WorkDir prepared for '$($app.Name)'. WorkDir='$($env.WorkDir)'; FilesDir='$($env.FilesDir)'." -InformationAction Continue

                # Wrap into .intunewin package.
                $packageParams = @{
                    WorkDir = $env.WorkDir
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
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Wrapping package for '$($app.Name)'. SetupFileName='$effectiveSetupFileName'." -InformationAction Continue
                $package = New-IntuneWinPackage @packageParams
                $package.IntuneWinPath | Should -Not -BeNullOrEmpty
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Package created for '$($app.Name)'. DisplayName='$($package.DisplayName)'; IntuneWinPath='$($package.IntuneWinPath)'." -InformationAction Continue

                # Build detection rule (unified signature: all builders accept $FilesDir).
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Building detection rule for '$($app.Name)'." -InformationAction Continue
                $DetectionRule = & $app.DetectionRuleBuilder $env.FilesDir
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Detection rule built for '$($app.Name)'. RuleType='$($DetectionRule.GetType().FullName)'." -InformationAction Continue

                # Upload to Intune.
                $intuneDisplayName = '{0}-{1}' -f $package.DisplayName, $script:IntuneDisplayNameSuffix
                Write-Information "[Intune Upload] Uploading $($app.TemplateVersion) app '$intuneDisplayName'..." -InformationAction Continue
                $publishParams = @{
                    FilePath = $package.IntuneWinPath
                    DisplayName = $intuneDisplayName
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
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Publishing '$($app.Name)'. DisplayName='$intuneDisplayName'; InstallCmd='$effectiveInstallCmd'; UninstallCmd='$effectiveUninstallCmd'." -InformationAction Continue
                $win32App = Publish-IntuneWin32App @publishParams
                $win32App | Should -Not -BeNullOrEmpty
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Published '$($app.Name)'. Win32AppId='$($win32App.id)'." -InformationAction Continue

                # Assign to test group.
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Assigning '$($app.Name)' to GroupID='$script:GroupID'." -InformationAction Continue
                Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID `
                    -Intent 'required' -Notification 'showAll' -Verbose
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Assigned '$($app.Name)' to GroupID='$script:GroupID'." -InformationAction Continue

                $script:UploadedApps[$app.Name] = @{
                    Win32AppId = $win32App.id
                    DisplayName = $intuneDisplayName
                    RegDisplayName = if ($app.RegDisplayName) { $app.RegDisplayName } else { $app.Name }
                    RegVersionValue = if ($app.RegVersionValue) { $app.RegVersionValue } else { $app.AppVersion }
                    RegVersionName = if ($app.RegVersionName) { $app.RegVersionName } else { 'DisplayVersion' }
                }
                Write-Information "[$($app.Name)] Uploaded and assigned successfully." -InformationAction Continue
            }

            $script:UploadedApps.Count | Should -Be $script:ParallelApps.Count
            }
            catch
            {
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Error "[Intune Debug] BatchUpload failed. ExceptionType='$($_.Exception.GetType().FullName)'; Message='$($_.Exception.Message)'"
                throw
            }
        }

        It '[INTUNE:InstallSync] MDM sync, then parallel poll for expected install outcomes' {
            $script:UploadedApps | Should -Not -BeNullOrEmpty -Because 'Upload step must succeed first'
            # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
            Write-Information "[Intune Debug] InstallSync started. UploadedApps='$($script:UploadedApps.Keys -join ', ')'." -InformationAction Continue

            Invoke-MdmSync
            Start-Sleep -Seconds 8
            Wait-IntuneManagementExtension

            $expectedDeferralAppNames = @(
                $script:ParallelApps |
                    Where-Object { $_.TemplateVersion -eq 'V4' -and (Get-PsadtForceCountdownDeferralExpectation -App $_).Expected } |
                    ForEach-Object { $_.Name }
            )
                    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                    Write-Information "[Intune Debug] InstallSync expected deferral apps='$($expectedDeferralAppNames -join ', ')'." -InformationAction Continue

            $helperPath = Join-Path $PSScriptRoot 'IntuneTestHelpers.ps1'
            $result = Invoke-ParallelAppPollWithRetry `
                -UploadedApps    $script:UploadedApps `
                -Operation       'Install' `
                -HelperScriptPath $helperPath `
                -NoRetryAppNames  $expectedDeferralAppNames
            # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
            Write-Information "[Intune Debug] InstallSync poll result. Succeeded='$($result.Succeeded -join ', ')'; Failed='$($result.Failed -join ', ')'." -InformationAction Continue

            # Store results and run post-install scripts for succeeded apps.
            foreach ($appName in $result.Succeeded)
            {
                $script:ParallelInstallResults[$appName] = $true

                $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
                if ($appConfig -and $appConfig.PostInstallScript)
                {
                    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                    Write-Information "[Intune Debug] Running PostInstallScript for '$appName'." -InformationAction Continue
                    & $appConfig.PostInstallScript
                    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                    Write-Information "[Intune Debug] Completed PostInstallScript for '$appName'." -InformationAction Continue
                }
            }
        }

        It '[INTUNE:<Name>_Install][<TemplateVersion>] <Name> should reach expected install outcome' -ForEach $script:ParallelApps {
            $failures = @()
            $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
            $expectForceCountdownDeferral = $false

            if ($appConfig -and $appConfig.TemplateVersion -eq 'V4')
            {
                $expectForceCountdownDeferral = (Get-PsadtForceCountdownDeferralExpectation -App $appConfig).Expected
            }

            if ($expectForceCountdownDeferral)
            {
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Install assertion for '$Name' expects ForceCountdown deferral." -InformationAction Continue
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
            elseif (-not $script:ParallelInstallResults[$Name])
            {
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Install assertion for '$Name' did not find success in ParallelInstallResults." -InformationAction Continue
                $failures += '[Install Status] app was not installed successfully via Intune MDM sync'
            }

            if ($appConfig -and -not $expectForceCountdownDeferral)
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
            # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
            Write-Information "[Intune Debug] UninstallSync started. ParallelInstallResults='$($script:ParallelInstallResults.Keys -join ', ')'." -InformationAction Continue

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
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] UninstallSync has no candidates after SkipUninstall filtering." -InformationAction Continue
                Set-ItResult -Skipped -Because 'All installed apps are filtered out from uninstall test by SkipUninstall.'
            }
            # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
            Write-Information "[Intune Debug] UninstallSync candidates='$($appsForUninstall -join ', ')'." -InformationAction Continue

            # Reassign all apps with uninstall intent.
            foreach ($appName in $appsForUninstall)
            {
                $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
                if ($appConfig -and $appConfig.PreUninstallScript)
                {
                    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                    Write-Information "[Intune Debug] Running PreUninstallScript for '$appName'." -InformationAction Continue
                    & $appConfig.PreUninstallScript
                    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                    Write-Information "[Intune Debug] Completed PreUninstallScript for '$appName'." -InformationAction Continue
                }

                $appInfo = $script:UploadedApps[$appName]
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Reassigning '$appName' to uninstall intent. Win32AppId='$($appInfo.Win32AppId)'." -InformationAction Continue
                Remove-IntuneWin32AppAssignmentGroup -ID $appInfo.Win32AppId -GroupID $script:GroupID
                Add-IntuneWin32AppAssignmentGroup -Include -ID $appInfo.Win32AppId -GroupID $script:GroupID `
                    -Intent 'uninstall' -Notification 'showAll' -Verbose
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Reassigned '$appName' to uninstall intent." -InformationAction Continue
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
            # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
            Write-Information "[Intune Debug] UninstallSync poll result. Succeeded='$($result.Succeeded -join ', ')'; Failed='$($result.Failed -join ', ')'." -InformationAction Continue

            # Store results for per-app assertion in subsequent It blocks.
            $script:ParallelUninstallResults = @{}
            foreach ($app in $result.Succeeded)
            {
                $script:ParallelUninstallResults[$app] = $true
            }
        }

        It '[INTUNE:<Name>_Uninstall][<TemplateVersion>] <Name> should be uninstalled' -ForEach ($script:ParallelApps | Where-Object { -not $_.SkipUninstall }) -AllowNullOrEmptyForEach {
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
            # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
            Write-Information "[Intune Debug] Context AfterAll started. UploadedAppsCount=$(if ($script:UploadedApps) { $script:UploadedApps.Count } else { 0 }); GroupID='$script:GroupID'." -InformationAction Continue

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
                # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                Write-Information "[Intune Debug] Starting Azure AD test group cleanup for GroupID='$script:GroupID'." -InformationAction Continue
                try
                {
                    Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/groups/$($script:GroupID)" -ErrorAction Stop
                    Start-Sleep -Seconds 5
                    # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
                    Write-Information "[Intune Debug] Finished Azure AD test group cleanup for GroupID='$script:GroupID'." -InformationAction Continue
                }
                catch
                {
                    Write-Warning "[Intune] Failed to clean up Azure AD test group '$($script:GroupID)': $($_.Exception.Message)"
                }
            }

            # TEMP-INTUNE-DEBUG: remove after diagnosing CI failure.
            Write-Information "[Intune Debug] Context AfterAll complete." -InformationAction Continue
        }
    }
}

#pragma warning restore PSPlaceOpenBrace
