#pragma warning disable PSPlaceOpenBrace

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
    }

    Context 'VLC - Wrap, Upload, Assign, Verify, Uninstall' {
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

            $script:VlcIntuneDisplayName = $package.DisplayName
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
    }

    Context 'WinSCP - Wrap, Upload, Assign, Verify, Uninstall' {
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
            $script:WinScpIntuneDisplayName = $package.DisplayName
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

            # --- Step 4: Trigger MDM sync and wait for IME ---
            Wait-IntuneManagementExtension

            # --- Step 5: Poll for app uninstallation on client ---
            $uninstallVerified = Wait-AppUninstallation `
                -DisplayName     $script:WinScpRegDisplayName `
                -ValueName       $script:WinScpRegVersionName `
                -ExpectedValue   $script:WinScpRegVersionValue
            $uninstallVerified | Should -BeTrue -Because "WinSCP should be removed from the Uninstall registry key within the polling window after uninstallation"
        }
    }
}

#pragma warning restore PSPlaceOpenBrace
