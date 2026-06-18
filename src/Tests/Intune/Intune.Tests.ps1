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
    . (Join-Path $script:_tfScriptRoot 'Private\IntuneTestHelpers.ps1')

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

    Context 'VLC - Wrap, Upload, Assign, Verify, Uninstall' -Skip {
        BeforeAll {
            $script:VlcAppFolderName = 'VLC'
            $script:VlcRegDisplayName = 'VLC media player'
            $script:VlcRegVersionValue = '3.0.23'
            $script:VlcRegVersionName = 'DisplayVersion'
            $script:VlcInstallSucceeded = $false
        }

        It 'VLC - wrap and upload to Intune, assign to group, verify installation' {
            $runnerScript = Join-Path $PSScriptRoot "VLC\Invoke-AppDeployToolkit.ps1"

            # --- Step 1: Prepare working directory ---
            $env = New-IntuneTestWorkDir `
                -AppFolderName      $script:VlcAppFolderName `
                -BasePath           $script:BasePath `
                -InstallerSourceDir 'C:\Tools\Intune\vlc' `
                -RunnerScriptPath   $runnerScript

            # --- Step 2: Wrap into .intunewin package ---
            $package = New-IntuneWinPackage `
                -WorkDir              $env.WorkDir `
                -IntuneWinAppUtilPath $script:IntuneWinAppUtil
            $package.IntuneWinPath | Should -Not -BeNullOrEmpty
            Test-Path $package.IntuneWinPath | Should -BeTrue

            # --- Step 3: Upload to Intune ---
            $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VLC media player' `
                -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '3.0.23'

            $script:VlcIntuneDisplayName = '{0}-{1}' -f $package.DisplayName, $script:IntuneDisplayNameSuffix
            $win32App = Publish-IntuneWin32App `
                -FilePath      $package.IntuneWinPath `
                -DisplayName   $script:VlcIntuneDisplayName `
                -DetectionRule $DetectionRule
            $win32App | Should -Not -BeNullOrEmpty

            # --- Step 4: Assign to test group ---
            Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID `
                -Intent 'required' -Notification 'showAll' -Verbose

            # --- Step 5: Trigger MDM sync and wait for IME ---
            Wait-IntuneManagementExtension

            # --- Step 6: Poll for app installation on client ---
            $installVerified = Wait-AppInstallation `
                -DisplayName     $script:VlcRegDisplayName `
                -ValueName       $script:VlcRegVersionName `
                -ExpectedValue   $script:VlcRegVersionValue
            $installVerified | Should -BeTrue -Because "VLC $($script:VlcRegVersionValue) should appear in the Uninstall registry key within the polling window"

            # Mark install as succeeded so the uninstall test can proceed.
            $script:VlcInstallSucceeded = $true
        }

        It 'VLC - Uninstall' {
            if (-not $script:VlcInstallSucceeded)
            {
                Set-ItResult -Skipped -Because 'VLC install test did not succeed'
            }

            # --- Step 1: Look up the existing Win32 app in Intune ---
            $win32App = Get-IntuneWin32App -DisplayName $script:VlcIntuneDisplayName -ErrorAction SilentlyContinue |
                Sort-Object -Property createdDateTime -Descending |
                Select-Object -First 1
            $win32App | Should -Not -BeNullOrEmpty -Because 'VLC Win32 app must exist in Intune from the install test'

            # --- Step 2: Remove existing app assignment ---
            Remove-IntuneWin32AppAssignmentGroup -ID $win32App.id -GroupID $script:GroupID

            # --- Step 3: Assign uninstall intent to the test app ---
            Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID `
                -Intent 'uninstall' -Notification 'showAll' -Verbose

            # --- Step 4: Trigger MDM sync and wait for IME ---
            Wait-IntuneManagementExtension

            # --- Step 5: Poll for app uninstallation on client ---
            $uninstallVerified = Wait-AppUninstallation `
                -DisplayName     $script:VlcRegDisplayName `
                -ValueName       $script:VlcRegVersionName `
                -ExpectedValue   $script:VlcRegVersionValue
            $uninstallVerified | Should -BeTrue -Because "VLC should be removed from the Uninstall registry key within the polling window after uninstallation"
        }

        AfterAll {
            # Clean up Intune Win32 app after tests.
            Write-Information "Cleaning up Intune Win32 app for VLC..." -InformationAction Continue
            if ($script:VlcIntuneDisplayName)
            {
                $win32App = Get-IntuneWin32App -DisplayName $script:VlcIntuneDisplayName -ErrorAction SilentlyContinue
                if ($win32App)
                {
                    Remove-IntuneWin32App -ID $win32App.id -Verbose
                }
            }
        }
    }

    Context 'WinSCP - Wrap, Upload, Assign, Verify, Uninstall' -Skip {
        BeforeAll {
            $script:WinScpAppFolderName = 'WinSCP'
            $script:WinScpRegDisplayName = 'WinSCP'
            $script:WinScpRegVersionValue = '6.5.6'
            $script:WinScpRegVersionName = 'DisplayVersion'
            $script:WinScpInstallSucceeded = $false
        }

        It 'WinSCP - wrap and upload to Intune, assign to group, verify installation' {
            $runnerScript = Join-Path $PSScriptRoot "$($script:WinScpAppFolderName)\Invoke-AppDeployToolkit.ps1"

            # --- Step 1: Prepare working directory ---
            $env = New-IntuneTestWorkDir `
                -AppFolderName      $script:WinScpAppFolderName `
                -BasePath           $script:BasePath `
                -InstallerSourceDir 'C:\Tools\Intune\WinSCP' `
                -RunnerScriptPath   $runnerScript

            # --- Step 2: Wrap into .intunewin package ---
            $package = New-IntuneWinPackage `
                -WorkDir              $env.WorkDir `
                -IntuneWinAppUtilPath $script:IntuneWinAppUtil
            $package.IntuneWinPath | Should -Not -BeNullOrEmpty
            Test-Path $package.IntuneWinPath | Should -BeTrue

            # --- Step 3: Build detection rule from MSI ProductCode ---
            $msiFile = Get-ChildItem -Path $env.FilesDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $msiFile)
            {
                throw 'No detection rule available for WinSCP - provide DetectionRule.ps1 or an MSI file'
            }
            $productCode = Get-MsiProductCode -MsiPath $msiFile.FullName
            $DetectionRule = New-IntuneWin32AppDetectionRuleMSI -ProductCode $productCode

            # --- Step 4: Upload to Intune ---
            $script:WinScpIntuneDisplayName = '{0}-{1}' -f $package.DisplayName, $script:IntuneDisplayNameSuffix
            $win32App = Publish-IntuneWin32App `
                -FilePath      $package.IntuneWinPath `
                -DisplayName   $script:WinScpIntuneDisplayName `
                -DetectionRule $DetectionRule
            $win32App | Should -Not -BeNullOrEmpty

            # --- Step 5: Assign to test group ---
            Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID `
                -Intent 'required' -Notification 'showAll' -Verbose

            # --- Step 6: Trigger MDM sync and wait for IME ---
            Wait-IntuneManagementExtension

            # --- Step 7: Poll for app installation on client ---
            $installVerified = Wait-AppInstallation `
                -DisplayName     $script:WinScpRegDisplayName `
                -ValueName       $script:WinScpRegVersionName `
                -ExpectedValue   $script:WinScpRegVersionValue
            $installVerified | Should -BeTrue -Because "WinSCP $($script:WinScpRegVersionValue) should appear in the Uninstall registry key within the polling window"

            # Mark install as succeeded so the uninstall test can proceed.
            $script:WinScpInstallSucceeded = $true
        }

        It 'WinSCP - Uninstall' {
            if (-not $script:WinScpInstallSucceeded)
            {
                Set-ItResult -Skipped -Because 'WinSCP install test did not succeed'
            }

            # --- Step 1: Look up the existing Win32 app in Intune ---
            $win32App = Get-IntuneWin32App -DisplayName $script:WinScpIntuneDisplayName -ErrorAction SilentlyContinue |
                Sort-Object -Property createdDateTime -Descending |
                Select-Object -First 1
            $win32App | Should -Not -BeNullOrEmpty -Because 'WinSCP Win32 app must exist in Intune from the install test'

            # --- Step 2: Remove existing app assignment ---
            Remove-IntuneWin32AppAssignmentGroup -ID $win32App.id -GroupID $script:GroupID

            # --- Step 3: Assign uninstall intent to the test app ---
            Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID `
                -Intent 'uninstall' -Notification 'showAll' -Verbose

            Start-Sleep -Seconds 5 # brief pause to allow the uninstall intent assignment to register before triggering sync

            # --- Step 4: Trigger MDM sync and wait for IME ---
            Wait-IntuneManagementExtension

            # --- Step 5: Poll for app uninstallation on client ---
            $uninstallVerified = Wait-AppUninstallation `
                -DisplayName     $script:WinScpRegDisplayName `
                -ValueName       $script:WinScpRegVersionName `
                -ExpectedValue   $script:WinScpRegVersionValue
            $uninstallVerified | Should -BeTrue -Because "WinSCP should be removed from the Uninstall registry key within the polling window after uninstallation"
        }
        <#
        AfterAll {
            # Clean up Intune Win32 app after tests.
            Write-Information "Cleaning up Intune Win32 app for WinSCP..." -InformationAction Continue
            if ($script:WinScpIntuneDisplayName)
            {
                $win32App = Get-IntuneWin32App -DisplayName $script:WinScpIntuneDisplayName -ErrorAction SilentlyContinue
                if ($win32App)
                {
                    Remove-IntuneWin32App -ID $win32App.id -Verbose
                }
            }
        }#>
    }

    Context 'Notepad++ - Upgrade' -Skip {
        BeforeAll {
            $script:NotepadAppFolderName = 'Notepad'
            $script:NotepadRegDisplayName = 'Notepad++'
            $script:NotepadRegVersionValue = '8.9.6.4'
            $script:NotepadRegVersionName = 'DisplayVersion'
            $script:NotepadInstallSucceeded = $false
        }

        It 'Notepad++ - Upgrade test with App Deploy Toolkit' {
            $runnerScript = Join-Path $PSScriptRoot "$($script:NotepadAppFolderName)\Invoke-AppDeployToolkit.ps1"


            # Install a lower version of Notepad++ as a prerequisite for the upgrade test.
            $installerDir = 'C:\Tools\Intune\Notepad8.9.6.1'
            $installerPath = Join-Path $installerDir 'npp.8.9.6.1.Installer.x64.exe'
            if (-not (Test-Path $installerPath))
            {
                New-Item -Path $installerDir -ItemType Directory -Force | Out-Null
                $downloadUrl = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.6.1/npp.8.9.6.1.Installer.x64.exe'
                Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
            }
            # Silent install the lower version.
            Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -NoNewWindow

            $newVersionDir = 'C:\Tools\Intune\Notepad8.9.6.4'
            if (-not (Test-Path $newVersionDir))
            {
                New-Item -Path $newVersionDir -ItemType Directory -Force | Out-Null
            }
            $downloadUrl = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.6.4/npp.8.9.6.4.Installer.x64.exe'
            $installerPath = Join-Path $newVersionDir 'npp.8.9.6.4.Installer.x64.exe'
            if (-not (Test-Path $installerPath))
            {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
            }

            # Pre -- the machine have install lower version of Notepad++ in registry, if not skip the test
            $lowerVersionInstalled = Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++" -Name 'DisplayVersion' -ErrorAction SilentlyContinue
            if (-not $lowerVersionInstalled -or $lowerVersionInstalled -ge $script:NotepadRegVersionValue)
            {
                Set-ItResult -Skipped -Because 'Notepad++ is not currently installed on the machine'
            }

            # --- Step 1: Prepare working directory ---
            $env = New-IntuneTestWorkDir `
                -AppFolderName      $script:NotepadAppFolderName `
                -BasePath           $script:BasePath `
                -InstallerSourceDir 'C:\Tools\Intune\Notepad8.9.6.4' `
                -RunnerScriptPath   $runnerScript

            # --- Step 2: Wrap into .intunewin package ---
            $package = New-IntuneWinPackage `
                -WorkDir              $env.WorkDir `
                -IntuneWinAppUtilPath $script:IntuneWinAppUtil
            $package.IntuneWinPath | Should -Not -BeNullOrEmpty
            Test-Path $package.IntuneWinPath | Should -BeTrue

            # --- Step 3: Build detection rule ---
            $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                -KeyPath "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++" `
                -ValueName "DisplayVersion" -StringComparisonOperator "equal" -StringComparisonValue "8.9.6.4"

            # --- Step 4: Upload to Intune ---
            $script:NotepadIntuneDisplayName = '{0}-{1}' -f $package.DisplayName, $script:IntuneDisplayNameSuffix
            $win32App = Publish-IntuneWin32App `
                -FilePath      $package.IntuneWinPath `
                -DisplayName   $script:NotepadIntuneDisplayName `
                -DetectionRule $DetectionRule
            $win32App | Should -Not -BeNullOrEmpty

            # --- Step 5: Assign to test group ---
            Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID `
                -Intent 'required' -Notification 'showAll' -Verbose

            # --- Step 6: Trigger MDM sync and wait for IME ---
            Wait-IntuneManagementExtension

            # --- Step 7: Poll for app installation on client ---
            $installVerified = Wait-AppInstallation `
                -DisplayName     $script:NotepadRegDisplayName `
                -ValueName       $script:NotepadRegVersionName `
                -ExpectedValue   $script:NotepadRegVersionValue
            $installVerified | Should -BeTrue -Because "Notepad++ $($script:NotepadRegVersionValue) should appear in the Uninstall registry key within the polling window"

            # Mark install as succeeded so the uninstall test can proceed.
            $script:NotepadInstallSucceeded = $true
        }

        <#
        AfterAll {
            # Clean up Intune Win32 app after tests.
            Write-Information "Cleaning up Intune Win32 app for Notepad++..." -InformationAction Continue
            if ($script:NotepadIntuneDisplayName)
            {
                $win32App = Get-IntuneWin32App -DisplayName $script:NotepadIntuneDisplayName -ErrorAction SilentlyContinue
                if ($win32App)
                {
                    Remove-IntuneWin32App -ID $win32App.id -Verbose
                }
            }
        }#>
    }

    Context 'Parallel Install - Batch Upload, Single Sync, Parallel Poll inatll and uninstall of multiple apps' {
        BeforeAll {
            # Define all apps to install in parallel.
            $script:ParallelApps = @(
                @{
                    Name              = 'VLC'
                    AppFolderName     = 'VLC'
                    InstallerSourceDir = 'C:\Tools\Intune\vlc'
                    RegDisplayName    = 'VLC media player'
                    RegVersionValue   = '3.0.23'
                    RegVersionName    = 'DisplayVersion'
                    DetectionRuleBuilder = {
                        New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                            -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VLC media player' `
                            -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '3.0.23'
                    }
                }
                @{
                    Name              = 'WinSCP'
                    AppFolderName     = 'WinSCP'
                    InstallerSourceDir = 'C:\Tools\Intune\WinSCP'
                    RegDisplayName    = 'WinSCP'
                    RegVersionValue   = '6.5.6'
                    RegVersionName    = 'DisplayVersion'
                    DetectionRuleBuilder = {
                        param($FilesDir)
                        $msiFile = Get-ChildItem -Path $FilesDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
                        if (-not $msiFile) { throw 'No MSI file found for WinSCP detection rule' }
                        $productCode = Get-MsiProductCode -MsiPath $msiFile.FullName
                        New-IntuneWin32AppDetectionRuleMSI -ProductCode $productCode
                    }
                }
                @{
                    Name              = 'Notepad++'
                    SkipUninstall     = $true
                    AppFolderName     = 'Notepad++'
                    InstallerSourceDir = 'C:\Tools\Intune\Notepad6.6.4'
                    RegDisplayName    = 'Notepad++'
                    RegVersionValue   = '6.6.4'
                    RegVersionName    = 'DisplayVersion'
                    PreInstallScript  = {
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
                    }
                    PostInstallScript  = {
                        $notepadExePath = 'C:\Program Files (x86)\Notepad++\notepad++.exe'
                        if (Test-Path $notepadExePath)
                        {
                            $notepadFileVersion = (Get-Item -Path $notepadExePath).VersionInfo.FileVersion
                            Write-Information "[Notepad++] FileVersion: $notepadFileVersion" -InformationAction Continue
                            $notepadFileVersion | Should -Match '^6(\.2\.3|\.23)(\.|$)' -Because 'Notepad++ main exe remains as the old version.'
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
                $runnerScript = Join-Path $PSScriptRoot "$($app.AppFolderName)\Invoke-AppDeployToolkit.ps1"
                $env = New-IntuneTestWorkDir `
                    -AppFolderName      $app.AppFolderName `
                    -BasePath           $script:BasePath `
                    -InstallerSourceDir $app.InstallerSourceDir `
                    -RunnerScriptPath   $runnerScript

                # Wrap into .intunewin package.
                $package = New-IntuneWinPackage `
                    -WorkDir              $env.WorkDir `
                    -IntuneWinAppUtilPath $script:IntuneWinAppUtil
                $package.IntuneWinPath | Should -Not -BeNullOrEmpty

                # Build detection rule.
                $DetectionRule = if ($app.Name -eq 'WinSCP')
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
                    Win32AppId      = $win32App.id
                    DisplayName     = $intuneDisplayName
                    RegDisplayName  = $app.RegDisplayName
                    RegVersionValue = $app.RegVersionValue
                    RegVersionName  = $app.RegVersionName
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
                } -ArgumentList $appInfo.RegDisplayName, $appInfo.RegVersionName, $appInfo.RegVersionValue, (Join-Path $PSScriptRoot 'Private\IntuneTestHelpers.ps1')
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
                        } -ArgumentList $appInfo.RegDisplayName, $appInfo.RegVersionName, $appInfo.RegVersionValue, (Join-Path $PSScriptRoot 'Private\IntuneTestHelpers.ps1')
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
                            try
                            {
                                & $appConfig.PostInstallScript
                            }
                            catch
                            {
                                Write-Warning "[$appName] Post-install validation failed but execution will continue. $($_.Exception.Message)"
                            }
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
                } -ArgumentList $appInfo.RegDisplayName, $appInfo.RegVersionName, $appInfo.RegVersionValue, (Join-Path $PSScriptRoot 'Private\IntuneTestHelpers.ps1')
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
                        } -ArgumentList $appInfo.RegDisplayName, $appInfo.RegVersionName, $appInfo.RegVersionValue, (Join-Path $PSScriptRoot 'Private\IntuneTestHelpers.ps1')
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
