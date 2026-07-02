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

    Context 'Parallel Install - V3,V4 - Batch Upload, Single Sync, Parallel Poll inatll and uninstall of multiple apps' {
        BeforeAll {
            # Define all apps to install in parallel.
            $script:ParallelApps = @(
                @{
                    Name = 'VLC'
                    TemplateName = 'VLC'
                    TemplateVersion = 'V4'
                    AppFolderName = 'VLC'
                    #InstallerSourceDir = 'C:\Tools\Intune\vlc'
                    RegDisplayName = 'VLC media player'
                    RegVersionValue = '3.0.23'
                    RegVersionName = 'DisplayVersion'
                    DetectionRuleBuilder = {
                        New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                            -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VLC media player' `
                            -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '3.0.23'
                    }
                }
                @{
                    Name = 'WinSCP'
                    TemplateName = 'WinSCP'
                    TemplateVersion = 'V4'
                    AppFolderName = 'WinSCP'
                    #InstallerSourceDir = 'C:\Tools\Intune\WinSCP'
                    RegDisplayName = 'WinSCP'
                    RegVersionValue = '6.5.6'
                    RegVersionName = 'DisplayVersion'
                    DetectionRuleBuilder = {
                        param($FilesDir)
                        $msiFile = Get-ChildItem -Path $FilesDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
                        if (-not $msiFile) { throw 'No MSI file found for WinSCP detection rule' }
                        $productCode = Get-MsiProductCode -MsiPath $msiFile.FullName
                        New-IntuneWin32AppDetectionRuleMSI -ProductCode $productCode
                    }
                }
                @{
                    Name = 'Notepad++'
                    SkipUninstall = $true
                    TemplateName = 'Notepad++'
                    TemplateVersion = 'V4'
                    AppFolderName = 'Notepad++'
                    #InstallerSourceDir = 'C:\Tools\Intune\Notepad6.6.4'
                    RegDisplayName = 'Notepad++'
                    RegVersionValue = '6.6.4'
                    RegVersionName = 'DisplayVersion'
                    PreInstallScript = {
                        # Install lower version as prerequisite for upgrade test.
                        $installerDir = 'C:\Tools\Intune\Notepad6.2.3'
                        $installerPath = Join-Path $installerDir 'npp.6.2.3.Installer.exe'
                        if (-not (Test-Path $installerPath))
                        {
                            New-Item -Path $installerDir -ItemType Directory -Force | Out-Null
                            Invoke-WebRequest -Uri 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-2/npp.6.2.3.Installer.exe' -OutFile $installerPath -UseBasicParsing
                        }
                        Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -NoNewWindow
                        $legacyNotepadExePath = Join-Path ${env:ProgramFiles(x86)} 'Notepad++\notepad++.exe'
                        if (Test-Path $legacyNotepadExePath)
                        {
                            Start-Process -FilePath $legacyNotepadExePath
                        }
                        else
                        {
                            Write-Warning "[Notepad++] Launch path not found: $legacyNotepadExePath"
                        }

                        # Download new version installer.
                        $newDir = 'C:\Tools\Intune\Notepad6.6.4'
                        $newPath = Join-Path $newDir 'npp.6.6.4.Installer.exe'
                        if (-not (Test-Path $newPath))
                        {
                            New-Item -Path $newDir -ItemType Directory -Force | Out-Null
                            Invoke-WebRequest -Uri 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-5/npp.6.6.4.Installer.exe' -OutFile $newPath -UseBasicParsing
                        }

                        # Keep a copy at the V4 template default file path.
                        $templateExpectedInstallerPath = 'C:\Tools\Intune\npp.6.6.4.Installer.exe'
                        Copy-Item -Path $newPath -Destination $templateExpectedInstallerPath -Force
                    }
                    PostInstallScript = {
                        $notepadExePath = 'C:\Program Files (x86)\Notepad++\notepad++.exe'
                        if (Test-Path $notepadExePath)
                        {
                            $notepadFileVersion = (Get-Item -Path $notepadExePath).VersionInfo.FileVersion
                            Write-Information "[Notepad++] FileVersion: $notepadFileVersion" -InformationAction Continue
                            if ($notepadFileVersion -match '^6\.23(\.|$)' -or $notepadFileVersion -match '^6\.2\.3(\.|$)')
                            {
                                Write-Information '[Notepad++] The currently retained version is the legacy version (6.23).' -InformationAction Continue
                            }
                            else
                            {
                                Write-Warning "[Notepad++] Main exe version is not an expected legacy value: $notepadFileVersion"
                            }
                        }
                        else
                        {
                            Write-Information "[Notepad++] File not found at: $notepadExePath" -InformationAction Continue
                        }
                    }
                    DetectionRuleBuilder = {
                        New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                            -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++' `
                            -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '6.6.4'
                    }
                }
                @{
                    Name = 'Digiexam'
                    TemplateName = 'Digiexam'
                    TemplateVersion = 'V3'
                    AppFolderName = 'Digiexam'
                    InstallerSourceFile = 'C:\Tools\Intune\Digiexam_26.1.24_x64_en-US.msi'
                    RegDisplayName = 'Digiexam'
                    RegVersionValue = '26.1.24'
                    RegVersionName = 'DisplayVersion'
                    DetectionRuleBuilder = {
                        param($FilesDir)
                        $msiFile = Get-ChildItem -Path $FilesDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
                        if (-not $msiFile) { throw 'No MSI file found for Digiexam detection rule' }
                        $productCode = Get-MsiProductCode -MsiPath $msiFile.FullName
                        New-IntuneWin32AppDetectionRuleMSI -ProductCode $productCode
                    }
                }
                @{
                    Name = 'Everything'
                    TemplateName = 'Everything'
                    TemplateVersion = 'V3'
                    AppFolderName = 'Everything'
                    InstallerSourceFile = 'C:\Tools\Intune\Everything-1.4.1.1032.x64-Setup.exe'
                    RegDisplayName = 'Everything 1.4.1.1032'
                    RegVersionValue = '1.4.1.1032'
                    RegVersionName = 'DisplayVersion'
                    DetectionRuleBuilder = {
                        New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                            -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Everything' `
                            -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '1.4.1.1032'
                    }
                }
            )
            $script:ParallelInstallResults = @{}
        }

        It 'Batch upload all apps and assign to group' {
            $script:UploadedApps = @{}

            foreach ($app in $script:ParallelApps)
            {
                Write-Information "--- Processing $($app.Name) ---" -InformationAction Continue

                # Run pre-install script if defined (e.g., install lower version for upgrade).
                if ($app.PreInstallScript)
                {
                    & $app.PreInstallScript
                }

                # Prepare working directory.
                if ( $app.TemplateVersion -eq 'V3')
                {
                    $runnerScript = Join-Path $PSScriptRoot "$($app.AppFolderName)\Deploy-Application.ps1"
                    $env = New-IntuneTestWorkDirV3 `
                        -AppFolderName       $app.AppFolderName `
                        -BasePath            $script:BasePath `
                        -InstallerSourceFile $app.InstallerSourceFile `
                        -RunnerScriptPath    $runnerScript
                }
                else
                {
                    $templateParamsPath = Join-Path $PSScriptRoot "..\V4\$($app.TemplateName)\New-ADTTemplate.params.ps1"
                    $env = New-IntuneTestWorkDirV4 `
                        -AppFolderName      $app.AppFolderName `
                        -BasePath           $script:BasePath `
                        -TemplateParamsPath $templateParamsPath
                }

                # Wrap into .intunewin package.
                if ($app.TemplateVersion -eq 'V3')
                {
                    $package = New-IntuneWinPackage `
                        -WorkDir              $env.WorkDir `
                        -IntuneWinAppUtilPath $script:IntuneWinAppUtil `
                        -SetupFileName "Deploy-Application.exe"
                }
                else
                {
                    $package = New-IntuneWinPackageV4 `
                        -WorkDir              $env.WorkDir `
                        -IntuneWinAppUtilPath $script:IntuneWinAppUtil
                }
                $package.IntuneWinPath | Should -Not -BeNullOrEmpty

                # Build detection rule.
                $DetectionRule = if ($app.Name -eq 'WinSCP' -or $app.Name -eq 'Digiexam')
                {
                    & $app.DetectionRuleBuilder $env.FilesDir
                }
                else
                {
                    & $app.DetectionRuleBuilder
                }

                # Upload to Intune.
                $intuneDisplayName = '{0}-{1}' -f $package.DisplayName, $script:IntuneDisplayNameSuffix
                $win32App = Publish-IntuneWin32App `
                    -FilePath      $package.IntuneWinPath `
                    -DisplayName   $intuneDisplayName `
                    -DetectionRule $DetectionRule
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

        It 'Single MDM sync, then parallel poll for all installations' {
            $script:UploadedApps | Should -Not -BeNullOrEmpty -Because 'Upload step must succeed first'

            Invoke-MdmSync

            Start-Sleep -Seconds 8

            # Trigger a single MDM sync for all assigned apps.
            Wait-IntuneManagementExtension

            # Parallel poll using ThreadJobs.
            $jobs = foreach ($appName in $script:UploadedApps.Keys)
            {
                $appInfo = $script:UploadedApps[$appName]
                Start-ThreadJob -Name "Poll-$appName" -ScriptBlock {
                    param($DisplayName, $ValueName, $ExpectedValue, $HelperPath)
                    . $HelperPath
                    Wait-AppInstallation -DisplayName $DisplayName -ValueName $ValueName -ExpectedValue $ExpectedValue -SkipImeRestartAndSync
                } -ArgumentList $appInfo.RegDisplayName, $appInfo.RegVersionName, $appInfo.RegVersionValue, (Join-Path $PSScriptRoot 'IntuneTestHelpers.ps1')
            }

            Write-Information "Waiting for $($jobs.Count) parallel installation polls..." -InformationAction Continue
            $jobs | Wait-Job | Out-Null

            # Collect results by job name to ensure correct app-to-result mapping.
            $failedApps = @()
            $succeededApps = @()
            $appsToCheck = @($script:UploadedApps.Keys)
            $maxRetryCount = 1

            for ($attempt = 0; $attempt -le $maxRetryCount; $attempt++)
            {
                if ($attempt -gt 0)
                {
                    Write-Information "[Parallel Install] Retry attempt $attempt for failed apps: $($appsToCheck -join ', ')" -InformationAction Continue

                    Invoke-MdmSync
                    Start-Sleep -Seconds 8
                    Wait-IntuneManagementExtension

                    $retryJobs = foreach ($appName in $appsToCheck)
                    {
                        $appInfo = $script:UploadedApps[$appName]
                        Start-ThreadJob -Name "PollRetry$attempt-$appName" -ScriptBlock {
                            param($DisplayName, $ValueName, $ExpectedValue, $HelperPath)
                            . $HelperPath
                            Wait-AppInstallation -DisplayName $DisplayName -ValueName $ValueName -ExpectedValue $ExpectedValue -SkipImeRestartAndSync
                        } -ArgumentList $appInfo.RegDisplayName, $appInfo.RegVersionName, $appInfo.RegVersionValue, (Join-Path $PSScriptRoot 'IntuneTestHelpers.ps1')
                    }

                    Write-Information "Waiting for $($retryJobs.Count) retry installation polls..." -InformationAction Continue
                    $retryJobs | Wait-Job | Out-Null
                }

                $nextFailedApps = @()
                foreach ($appName in $appsToCheck)
                {
                    $jobName = if ($attempt -eq 0) { "Poll-$appName" } else { "PollRetry$attempt-$appName" }
                    $jobResult = Get-Job -Name $jobName -ErrorAction SilentlyContinue | Receive-Job
                    if ($jobResult -ne $true)
                    {
                        Write-Information "[$appName] Installation poll result (attempt $attempt): $jobResult" -InformationAction Continue
                        $nextFailedApps += $appName
                    }
                    else
                    {
                        if (-not ($succeededApps -contains $appName))
                        {
                            $succeededApps += $appName
                        }
                        $script:ParallelInstallResults[$appName] = $true

                        $appConfig = $script:ParallelApps | Where-Object { $_.Name -eq $appName } | Select-Object -First 1
                        if ($appConfig -and $appConfig.PostInstallScript)
                        {
                            & $appConfig.PostInstallScript
                        }
                    }
                }

                if ($attempt -gt 0)
                {
                    $retryJobs | Remove-Job -Force
                }

                $appsToCheck = @($nextFailedApps)
                if (-not $appsToCheck)
                {
                    break
                }
            }

            $failedApps = @($appsToCheck)
            $jobs | Remove-Job -Force

            Write-Information "[Parallel Install] Succeeded: $(if ($succeededApps) { $succeededApps -join ', ' } else { 'none' })" -InformationAction Continue
            Write-Information "[Parallel Install] Failed: $(if ($failedApps) { $failedApps -join ', ' } else { 'none' })" -InformationAction Continue

            $failedApps | Should -BeNullOrEmpty -Because "All apps should install successfully. Failed: $($failedApps -join ', ')"
        }

        It 'Parallel uninstall all apps' {
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
            # Single sync for all uninstalls.
            Wait-IntuneManagementExtension

            # Parallel poll for uninstallation.
            $jobs = foreach ($appName in $appsForUninstall)
            {
                $appInfo = $script:UploadedApps[$appName]
                Start-ThreadJob -Name "Uninstall-$appName" -ScriptBlock {
                    param($DisplayName, $ValueName, $ExpectedValue, $HelperPath)
                    . $HelperPath
                    Wait-AppUninstallation -DisplayName $DisplayName -ValueName $ValueName -ExpectedValue $ExpectedValue -SkipImeRestartAndSync
                } -ArgumentList $appInfo.RegDisplayName, $appInfo.RegVersionName, $appInfo.RegVersionValue, (Join-Path $PSScriptRoot 'IntuneTestHelpers.ps1')
            }

            Write-Information "Waiting for $($jobs.Count) parallel uninstallation polls..." -InformationAction Continue
            $jobs | Wait-Job | Out-Null

            # Collect results by job name to ensure correct app-to-result mapping.
            $failedApps = @()
            $succeededApps = @()
            $appsToCheck = @($appsForUninstall)
            $maxRetryCount = 1

            for ($attempt = 0; $attempt -le $maxRetryCount; $attempt++)
            {
                if ($attempt -gt 0)
                {
                    Write-Information "[Parallel Uninstall] Retry attempt $attempt for failed apps: $($appsToCheck -join ', ')" -InformationAction Continue

                    Invoke-MdmSync
                    Start-Sleep -Seconds 8
                    Wait-IntuneManagementExtension

                    $retryJobs = foreach ($appName in $appsToCheck)
                    {
                        $appInfo = $script:UploadedApps[$appName]
                        Start-ThreadJob -Name "UninstallRetry$attempt-$appName" -ScriptBlock {
                            param($DisplayName, $ValueName, $ExpectedValue, $HelperPath)
                            . $HelperPath
                            Wait-AppUninstallation -DisplayName $DisplayName -ValueName $ValueName -ExpectedValue $ExpectedValue -SkipImeRestartAndSync
                        } -ArgumentList $appInfo.RegDisplayName, $appInfo.RegVersionName, $appInfo.RegVersionValue, (Join-Path $PSScriptRoot 'IntuneTestHelpers.ps1')
                    }

                    Write-Information "Waiting for $($retryJobs.Count) retry uninstallation polls..." -InformationAction Continue
                    $retryJobs | Wait-Job | Out-Null
                }

                $nextFailedApps = @()
                foreach ($appName in $appsToCheck)
                {
                    $jobName = if ($attempt -eq 0) { "Uninstall-$appName" } else { "UninstallRetry$attempt-$appName" }
                    $jobResult = Get-Job -Name $jobName -ErrorAction SilentlyContinue | Receive-Job
                    if ($jobResult -ne $true)
                    {
                        Write-Information "[$appName] Uninstallation poll result (attempt $attempt): $jobResult" -InformationAction Continue
                        $nextFailedApps += $appName
                    }
                    else
                    {
                        if (-not ($succeededApps -contains $appName))
                        {
                            $succeededApps += $appName
                        }
                    }
                }

                if ($attempt -gt 0)
                {
                    $retryJobs | Remove-Job -Force
                }

                $appsToCheck = @($nextFailedApps)
                if (-not $appsToCheck)
                {
                    break
                }
            }

            $failedApps = @($appsToCheck)
            $jobs | Remove-Job -Force

            Write-Information "[Parallel Uninstall] Succeeded: $(if ($succeededApps) { $succeededApps -join ', ' } else { 'none' })" -InformationAction Continue
            Write-Information "[Parallel Uninstall] Failed: $(if ($failedApps) { $failedApps -join ', ' } else { 'none' })" -InformationAction Continue

            $failedApps | Should -BeNullOrEmpty -Because "All apps should uninstall successfully. Failed: $($failedApps -join ', ')"
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

    <#
    AfterAll {
        # Clean up Azure AD test group.
        Write-Information "Cleaning up Azure AD test group..." -InformationAction Continue
        if ($script:GroupID)
        {
            Remove-MgGroup -GroupId $script:GroupID -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
    }#>
}

#pragma warning restore PSPlaceOpenBrace
