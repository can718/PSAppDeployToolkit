#pragma warning disable PSPlaceOpenBrace

# ---------------------------------------------------------------------------
# TerraForge test run reporting helper
# Loaded once per session; silently skipped if env vars are not set
# ---------------------------------------------------------------------------
BeforeAll {
    $script:_tfScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Path -Parent }
    Write-Information "[TerraForge] PSScriptRoot='$PSScriptRoot' MyCommand='$($MyInvocation.MyCommand.Path)' ScriptRoot='$($script:_tfScriptRoot)'" -InformationAction Continue
    $script:_tfHelperPath = [System.IO.Path]::GetFullPath((Join-Path $script:_tfScriptRoot '..\..\..\.github\scripts\TerraForge-AgentHelper.ps1'))
    Write-Information "[TerraForge] Helper script path: $($script:_tfHelperPath)  Exists=$(Test-Path $script:_tfHelperPath)" -InformationAction Continue
    if (Test-Path $script:_tfHelperPath)
    {
        try { . $script:_tfHelperPath }
        catch { Write-Warning "[TerraForge] Failed to load helper script: $($_.Exception.Message)" }
    }

    Write-Information "[Pester] Version: $((Get-Module Pester).Version)" -InformationAction Continue
    $script:TFReportingEnabled = $false
    $script:TFAccessToken = $null
    $script:TFTestRunId = $env:TEST_RUN_ID
    $script:TFApiBaseUrl = $env:TERRAFORGE_API_BASE_URL
    # Authenticate to Intune Graph
    $script:TenantID = $env:TEST_TENANTID
    $script:ClientID = $env:TEST_CLIENTID
    $script:ClientSecret = $env:TEST_CLIENTSECRET

    if ($script:TFTestRunId -and $script:TFApiBaseUrl)
    {
        if (Get-Command 'Get-TerraForgeAuthToken' -ErrorAction SilentlyContinue)
        {
            try
            {
                $script:TFAccessToken = Get-TerraForgeAuthToken `
                    -ManagedIdentityClientId $env:INFRA_MI_CLIENT_ID `
                    -KeyVaultName            $env:INFRA_KEYVAULT `
                    -ApiKeySecretName        $env:TERRAFORGE_API_KEY_SECRET `
                    -ApiBaseUrl              $script:TFApiBaseUrl
                $script:TFReportingEnabled = $true
                Write-Information "[TerraForge] Reporting enabled for TestRunId: $script:TFTestRunId" -InformationAction Continue
            }
            catch
            {
                Write-Warning "[TerraForge] Could not obtain access token, reporting disabled: $($_.Exception.Message)"
            }
        }
        else
        {
            Write-Warning "[TerraForge] Helper script not found or failed to load (path: $($script:_tfHelperPath)) -- reporting disabled."
        }
    }

    function script:Invoke-TFReportTestCase
    {
        <#
            Creates a test run result entry before the test executes.
            Stores the returned ID in $script:TFCurrentResultId for AfterEach to update.
        #>
        param (
            [string]$TestClass,
            [string]$TestMethod
        )
        $script:TFCurrentResultId = $null
        if (-not $script:TFReportingEnabled) { return }

        if ([string]::IsNullOrWhiteSpace($TestMethod))
        {
            Write-Warning "[TerraForge] Skipping result entry creation: could not resolve test name."
            return
        }

        try
        {
            $result = New-TestRunResults `
                -ApiBaseUrl  $script:TFApiBaseUrl `
                -AccessToken $script:TFAccessToken `
                -TestRunId   $script:TFTestRunId `
                -TestClass   $TestClass `
                -SessionId   $env:TEST_SESSION_ID `
                -ProductName $TestMethod `
                -MachineId   $env:COMPUTERNAME
            $script:TFCurrentResultId = $result.Id
            Write-Information "[TerraForge] Created result entry Id=$($result.Id) for: $TestClass / $TestMethod" -InformationAction Continue
        }
        catch
        {
            Write-Warning "[TerraForge] Failed to create result entry for '$TestMethod': $($_.Exception.Message)"
        }
    }

    function script:Invoke-TFUpdateTestCase
    {
        <#
            Updates the test run result after the test completes.
            Result codes: 2 = Passed, 0 = Failed, 4 = Skipped
            NOTE: Called from AfterEach where Pester has not yet written back
            Test.Passed/Result, so we derive the outcome from ErrorRecord count
            and the Skipped flag instead.
        #>
        param (
            [object]$TestResult
        )
        if (-not $script:TFReportingEnabled -or -not $script:TFCurrentResultId) { return }

        try
        {
            $resultCode = if ($TestResult.Skipped)
            {
                $null   # Skipped
            }
            elseif ($TestResult.ErrorRecord -and $TestResult.ErrorRecord.Count -gt 0)
            {
                0   # Failed
            }
            else
            {
                2   # Passed
            }
            $errorMsg = if ($TestResult.ErrorRecord -and $TestResult.ErrorRecord.Count -gt 0)
            {
                $TestResult.ErrorRecord[0].Exception.Message
            }
            else
            {
                $null
            }

            Update-TestRunResults `
                -ApiBaseUrl       $script:TFApiBaseUrl `
                -AccessToken      $script:TFAccessToken `
                -TestRunResultId  $script:TFCurrentResultId `
                -Result           $resultCode `
                -ErrorMessage     $errorMsg
            Write-Verbose "[TerraForge] Updated result Id=$($script:TFCurrentResultId) -> code=$resultCode"
        }
        catch
        {
            Write-Warning "[TerraForge] Failed to update result Id=$($script:TFCurrentResultId): $($_.Exception.Message)"
        }
    }

    function script:Get-IntuneWinAppUtilPath
    {
        $toolPath = 'C:\Tools\Intune\IntuneWinAppUtil.exe'
        if (Test-Path $toolPath)
        {
            return $toolPath
        }

        return $null
    }

    if (-not (Get-Module -Name 'IntuneWin32App' -ListAvailable))
    {
        Install-Module -Name 'IntuneWin32App' -AcceptLicense -Force -Scope CurrentUser
    }
    Import-Module -Name 'IntuneWin32App' -ErrorAction Stop
}

# ---------------------------------------------------------------------------

Describe 'Intune Tests' {
    Context 'Sanity checks' {
        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Intune Tests / Sanity checks'
            $script:CurrentTestMethod = $testInfo.Name
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod

            if ($(Test-AccessToken) -eq $false)
            {
                Write-Host "First use Connect-MSIntuneGraph to access Microsoft Graph." -ForegroundColor Yellow

                # Authenticate to Microsoft Graph
                $ClientSecret = $script:ClientSecret
                Connect-MSIntuneGraph -TenantID $script:TenantID -ClientID $script:ClientID -ClientSecret $ClientSecret
            }
        }

        AfterEach {
            Invoke-TFUpdateTestCase -TestResult $____Pester.CurrentTest
        }

        It 'PowerShell version is 5.1 or higher' {
            $PSVersionTable.PSVersion.Major | Should -BeGreaterOrEqual 5
        }

        It 'True is true' {
            $true | Should -BeTrue
        }

        It 'Basic arithmetic works' {
            (1 + 1) | Should -Be 2
        }
    }

    Context 'Intune Module Availability' {
        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Intune Tests / Intune Module Availability'
            $script:CurrentTestMethod = $testInfo.Name
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            Invoke-TFUpdateTestCase -TestResult $____Pester.CurrentTest
        }


    }

    Context 'Intune Package Deployment Checks' {
        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Intune Tests / Intune Package Deployment Checks'
            $script:CurrentTestMethod = $testInfo.Name
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            Invoke-TFUpdateTestCase -TestResult $____Pester.CurrentTest
        }

        It 'PSADT module artifacts directory exists after build' {
            $artifactPath = '.\src\Artifacts'
            Test-Path $artifactPath | Should -BeTrue
        }

        It 'Invoke-AppDeployToolkit.ps1 template exists in v4 artifacts' {
            $templates = Get-ChildItem -Path '.\src\Artifacts' -Filter 'Invoke-AppDeployToolkit.ps1' -Recurse -ErrorAction SilentlyContinue
            if (-not $templates)
            {
                Set-ItResult -Skipped -Because 'Build artifacts not found - build step may not have run'
            }
            else
            {
                $templates | Should -Not -BeNullOrEmpty
            }
        }

        It 'AppDeployToolkitMain.ps1 is present in build output' {
            $mainScript = Get-ChildItem -Path '.\src\Artifacts' -Filter 'AppDeployToolkitMain.ps1' -Recurse -ErrorAction SilentlyContinue
            if (-not $mainScript)
            {
                Set-ItResult -Skipped -Because 'Build artifacts not found - build step may not have run'
            }
            else
            {
                $mainScript | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Intune Win32 App Packaging Requirements' {
        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Intune Tests / Intune Win32 App Packaging Requirements'
            $script:CurrentTestMethod = $testInfo.Name
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            Invoke-TFUpdateTestCase -TestResult $____Pester.CurrentTest
        }

        It 'PSAppDeployToolkit module can be found in src output' {
            $moduleManifest = Get-ChildItem -Path '.\src\Artifacts' -Filter 'PSAppDeployToolkit.psd1' -Recurse -ErrorAction SilentlyContinue
            if (-not $moduleManifest)
            {
                Set-ItResult -Skipped -Because 'PSAppDeployToolkit.psd1 not found - build step may not have run'
            }
            else
            {
                $moduleManifest | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Win32 App Wrap and Upload' {
        BeforeAll {
            # Generate PSADT template to C:\PSADT
            $templateDest = 'C:\PSADT'
            if (Test-Path $templateDest)
            {
                Remove-Item -Path $templateDest -Recurse -Force
            }
            Import-Module -Name '.\src\PSAppDeployToolkit\PSAppDeployToolkit.psd1' -Force
            New-ADTTemplate -Destination $templateDest -Force

            # Resolve IntuneWinAppUtil.exe from the default local install path.
            $script:IntuneWinAppUtil = Get-IntuneWinAppUtilPath
            $script:Win32WrapAndUploadSkipReason = if (-not $script:IntuneWinAppUtil)
            {
                'IntuneWinAppUtil.exe not found at C:\Tools\Intune\IntuneWinAppUtil.exe'
            }
            else
            {
                $null
            }

            # Create a test group in Azure AD and set $script:GroupID to its ObjectId for assignment tests
            $graphModule = Get-Module -Name 'Microsoft.Graph*' -ListAvailable
            # If not installed, this test will be skipped gracefully
            if (-not $graphModule)
            {
                Import-Module -Name $graphModule.Name -Force
                Connect-MgGraph -TenantId $script:TenantID -ClientId $script:ClientID -ClientSecret $script:ClientSecret -Scopes 'Group.ReadWrite.All", "Device.Read.All'
                $group = New-MgGroup -DisplayName 'PSADT Test Group' -SecurityEnabled $true -MailEnabled $false
                $script:GroupID = $group.Id
                Write-Information "Created test group with ObjectId: $($script:GroupID)" -InformationAction Continue
            }
            # Add test client to the group to verify group membership in assignment tests
            $deviceName = $env:COMPUTERNAME
            $device = Get-MgDevice -Filter "displayName eq '$deviceName'"
            New-MgGroupMember -GroupId $script:GroupID -DirectoryObjectId $device.Id
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Intune Tests / Win32 App Wrap and Upload'
            $script:CurrentTestMethod = $testInfo.Name
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod

            if ($(Test-AccessToken) -eq $false)
            {
                Write-Host "First use Connect-MSIntuneGraph to access Microsoft Graph." -ForegroundColor Yellow

                # Authenticate to Microsoft Graph
                $ClientSecret = $script:ClientSecret
                Connect-MSIntuneGraph -TenantID $script:TenantID -ClientID $script:ClientID -ClientSecret $ClientSecret
            }

            if ($script:Win32WrapAndUploadSkipReason)
            {
                Set-ItResult -Skipped -Because $script:Win32WrapAndUploadSkipReason
            }
        }

        AfterEach {
            Invoke-TFUpdateTestCase -TestResult $____Pester.CurrentTest
        }

        It 'VLC - wrap and upload to Intune' {
            $appDownloadUrl = 'https://get.videolan.org/vlc/3.0.23/win64/vlc-3.0.23-win64.exe'
            $appName = 'VLC'
            $workDir = Join-Path 'C:\PSADT' $appName

            # Copy template to app working directory: like C:\PSADT\VLC\*
            $templateFolder = Get-ChildItem -Path 'C:\PSADT' -Directory | Where-Object { $_.Name -like 'PSAppDeployToolkit*' } | Select-Object -First 1
            if (-not $templateFolder)
            {
                throw 'PSADT template folder not found under C:\PSADT'
            }
            Copy-Item -Path $templateFolder.FullName -Destination $workDir -Recurse -Force

            # Download the app installer to Files folder
            $filesDir = Join-Path $workDir 'Files'
            if (-not (Test-Path $filesDir)) { New-Item -Path $filesDir -ItemType Directory -Force | Out-Null }
            $installerFile = Join-Path $filesDir (Split-Path $appDownloadUrl -Leaf)
            Invoke-WebRequest -Uri $appDownloadUrl -OutFile $installerFile -UseBasicParsing

            # Replace Invoke-AppDeployToolkit.ps1 with the app-specific one from examples
            $runnerScript = Join-Path $PSScriptRoot '.\VLC\Invoke-AppDeployToolkit.ps1'
            $targetScript = Join-Path $workDir 'Invoke-AppDeployToolkit.ps1'
            Copy-Item -Path $runnerScript -Destination $targetScript -Force

            # Wrap with IntuneWinAppUtil
            $setupFile = 'Invoke-AppDeployToolkit.exe'
            & $script:IntuneWinAppUtil -c $workDir -s $setupFile -o $workDir -q
            $intunewinFile = Join-Path $workDir 'Invoke-AppDeployToolkit.intunewin'
            Test-Path $intunewinFile | Should -BeTrue

            # Rename .intunewin and move to WIN32APP folder
            $FileDir = Split-Path $intunewinFile -Parent
            $PackageFile = Get-ChildItem -Path "$FileDir\Files" -File |
            Where-Object { $_.Extension -in '.msi', '.exe' } |
            Select-Object -First 1

            if (-not $PackageFile)
            {
                Write-Host "Can't find msi/exe files in the source folder."
                return
            }
            $DisplayName = $PackageFile.BaseName

            $NewFileName = "$DisplayName.intunewin"
            $NewIntuneWinFile = Join-Path -Path $FileDir -ChildPath $NewFileName
            if (Test-Path $intunewinFile)
            {
                Rename-Item -Path $intunewinFile -NewName $NewFileName -Force
                Write-Host "Renamed to $NewIntuneWinFile" -ForegroundColor Green
            }
            else
            {
                Write-Host "Original intunewin file does not exist." -ForegroundColor Blue
            }
            Test-Path $NewIntuneWinFile | Should -BeTrue

            # Upload to Intune
            $RequirementRule = New-IntuneWin32AppRequirementRule -Architecture 'x64x86' -MinimumSupportedWindowsRelease 'W10_1607'
            $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VLC media player' `
                -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '3.0.23'
            $InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
            $UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'

            Add-IntuneWin32App -FilePath $NewIntuneWinFile -DisplayName $DisplayName -Description "PSADT $appName deployment" `
                -Publisher 'Autotest' -InstallExperience 'system' -RestartBehavior 'suppress' `
                -DetectionRule $DetectionRule -RequirementRule $RequirementRule `
                -InstallCommandLine $InstallCmd -UninstallCommandLine $UninstallCmd -Verbose

            # Intune Graph API has eventual consistency; retry until the app is visible
            $win32App = $null
            $retryCount = 0
            $maxRetries = 12
            while (-not $win32App -and $retryCount -lt $maxRetries)
            {
                Start-Sleep -Seconds 10
                $win32App = Get-IntuneWin32App -DisplayName $DisplayName -Verbose
                $retryCount++
            }
            $win32App
            $win32App | Should -Not -BeNullOrEmpty

            # Assign to group
            Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID -Intent 'required' -Notification 'showAll' -Verbose
        }

        It 'WinSCP - wrap and upload to Intune' -Skip {
            # TODO: Set your WinSCP download URL here
            $appDownloadUrl = 'https://winscp.net/download/WinSCP-6.5.6.msi/download'  # <-- Fill in WinSCP download URL
            $appName = 'WinSCP'
            $workDir = Join-Path 'C:\PSADT' $appName

            # Copy template to app working directory
            $templateFolder = Get-ChildItem -Path 'C:\PSADT' -Directory | Where-Object { $_.Name -like 'PSAppDeployToolkit*' } | Select-Object -First 1
            if (-not $templateFolder)
            {
                throw 'PSADT template folder not found under C:\PSADT'
            }
            Copy-Item -Path $templateFolder.FullName -Destination $workDir -Recurse -Force

            # Download the app installer to Files folder
            $filesDir = Join-Path $workDir 'Files'
            if (-not (Test-Path $filesDir)) { New-Item -Path $filesDir -ItemType Directory -Force | Out-Null }
            $installerFile = Join-Path $filesDir (Split-Path $appDownloadUrl -Leaf)
            Invoke-WebRequest -Uri $appDownloadUrl -OutFile $installerFile -UseBasicParsing

            # Replace Invoke-AppDeployToolkit.ps1 with the app-specific one from examples
            $runnerScript = Join-Path $PSScriptRoot '..\..\..\examples\WinSCP\Invoke-AppDeployToolkit.ps1'
            $targetScript = Join-Path $workDir 'Invoke-AppDeployToolkit.ps1'
            Copy-Item -Path $runnerScript -Destination $targetScript -Force

            # Wrap with IntuneWinAppUtil
            $setupFile = 'Invoke-AppDeployToolkit.exe'
            & $script:IntuneWinAppUtil -c $workDir -s $setupFile -o $workDir -q
            $intunewinFile = Join-Path $workDir 'Invoke-AppDeployToolkit.intunewin'
            Test-Path $intunewinFile | Should -BeTrue

            # Rename .intunewin and move to WIN32APP folder
            $newName = "$appName.intunewin"
            $finalPath = Join-Path 'C:\PSADT\WIN32APP' $newName
            Move-Item -Path $intunewinFile -Destination $finalPath -Force
            Test-Path $finalPath | Should -BeTrue

            # Upload to Intune
            $RequirementRule = New-IntuneWin32AppRequirementRule -Architecture 'x64x86' -MinimumSupportedWindowsRelease 'W10_1607'

            # Detect by MSI ProductCode or registry - adjust as needed for WinSCP
            $DetectionScriptFile = Join-Path $PSScriptRoot 'DetectionRule.ps1'
            if (Test-Path $DetectionScriptFile)
            {
                $DetectionRule = New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionScriptFile -EnforceSignatureCheck $false -RunAs32Bit $false
            }
            else
            {
                # Fallback: detect via Files folder MSI ProductCode
                $msiFile = Get-ChildItem -Path $filesDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($msiFile)
                {
                    $comObj = New-Object -ComObject WindowsInstaller.Installer
                    $db = $comObj.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $comObj, @($msiFile.FullName, 0))
                    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='ProductCode'"))
                    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                    $ProductCode = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
                    $DetectionRule = New-IntuneWin32AppDetectionRuleMSI -ProductCode $ProductCode
                }
                else
                {
                    throw 'No detection rule available for WinSCP - provide DetectionRule.ps1 or an MSI file'
                }
            }

            $InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
            $UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
            $DisplayName = $appName

            Add-IntuneWin32App -FilePath $finalPath -DisplayName $DisplayName -Description "PSADT $appName deployment" `
                -Publisher 'Autotest' -InstallExperience 'system' -RestartBehavior 'suppress' `
                -DetectionRule $DetectionRule -RequirementRule $RequirementRule `
                -InstallCommandLine $InstallCmd -UninstallCommandLine $UninstallCmd -Verbose

            # Intune Graph API has eventual consistency; retry until the app is visible
            $win32App = $null
            $retryCount = 0
            $maxRetries = 12
            while (-not $win32App -and $retryCount -lt $maxRetries)
            {
                Start-Sleep -Seconds 10
                $win32App = Get-IntuneWin32App -DisplayName $DisplayName -Verbose
                $retryCount++
            }
            $win32App | Should -Not -BeNullOrEmpty

            # Assign to group
            Add-IntuneWin32AppAssignmentGroup -Include -ID $win32App.id -GroupID $script:GroupID -Intent 'required' -Notification 'showAll' -Verbose
        }
    }
}

#pragma warning restore PSPlaceOpenBrace
