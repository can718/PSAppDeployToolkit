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

    if ($script:TFTestRunId -and $script:TFApiBaseUrl)
    {
        if (Get-Command 'Get-TerraForgeAuthToken' -ErrorAction SilentlyContinue)
        {
            try
            {
                $script:TFAccessToken = Get-TerraForgeAuthToken `
                    -ManagedIdentityClientId $env:INFRA_MI_CLIENT_ID `
                    -KeyVaultName $env:INFRA_KEYVAULT `
                    -ApiKeySecretName $env:TERRAFORGE_API_KEY_SECRET `
                    -ApiBaseUrl $script:TFApiBaseUrl
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
        if (-not $script:TFReportingEnabled)
        {
            return
        }

        if ([string]::IsNullOrWhiteSpace($TestMethod))
        {
            Write-Warning "[TerraForge] Skipping result entry creation: could not resolve test name."
            return
        }

        try
        {
            $result = New-TestRunResults `
                -ApiBaseUrl $script:TFApiBaseUrl `
                -AccessToken $script:TFAccessToken `
                -TestRunId $script:TFTestRunId `
                -TestClass $TestClass `
                -SessionId $env:TEST_SESSION_ID `
                -ProductName $TestMethod `
                -MachineId $env:COMPUTERNAME
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
        if (-not $script:TFReportingEnabled -or -not $script:TFCurrentResultId)
        {
            return
        }
        try
        {
            # $TestResult.Result is still "Running" inside AfterEach.
            # Derive outcome: Skipped flag is set before AfterEach runs;
            # ErrorRecord accumulates test body errors before AfterEach runs.
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
                -ApiBaseUrl $script:TFApiBaseUrl `
                -AccessToken $script:TFAccessToken `
                -TestRunResultId $script:TFCurrentResultId `
                -Result $resultCode `
                -ErrorMessage $errorMsg
            Write-Verbose "[TerraForge] Updated result Id=$($script:TFCurrentResultId) -> code=$resultCode"
        }
        catch
        {
            Write-Warning "[TerraForge] Failed to update result Id=$($script:TFCurrentResultId): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------

Describe 'Additional Tests' {
    Context 'Sanity checks' {
        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Additional Tests / Sanity checks'
            $script:CurrentTestMethod = $testInfo.Name
            Write-Verbose "[BeforeEach] TestClass: $($script:CurrentTestClass)"
            Write-Verbose "[BeforeEach] TestMethod: $($script:CurrentTestMethod)"
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest
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
}

Describe 'PSADT Build Template Validation' {
    Context 'Template paths from build output' {

        BeforeAll {
            $script:v3Dir = $env:PSADT_TEMPLATE_V3_DIR
            $script:v4Dir = $env:PSADT_TEMPLATE_V4_DIR
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'PSADT Build Template Validation / Template paths from build output'
            $script:CurrentTestMethod = $testInfo.Name
            Write-Verbose "[BeforeEach] TestClass: $($script:CurrentTestClass)"
            Write-Verbose "[BeforeEach] TestMethod: $($script:CurrentTestMethod)"
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest
        }

        It 'PSADT_TEMPLATE_V3_DIR environment variable is set' {
            $script:v3Dir | Should -Not -BeNullOrEmpty
        }

        It 'PSADT_TEMPLATE_V4_DIR environment variable is set' {
            $script:v4Dir | Should -Not -BeNullOrEmpty
        }

        It 'V3 template directory exists on disk' {
            if (-not $script:v3Dir)
            {
                Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V3_DIR not set'
                return
            }
            Test-Path $script:v3Dir | Should -BeTrue
        }

        It 'V4 template directory exists on disk' {
            if (-not $script:v4Dir)
            {
                Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V4_DIR not set'
                return
            }
            Test-Path $script:v4Dir | Should -BeTrue
        }

        It 'V3 template contains AppDeployToolkit subfolder' {
            if (-not $script:v3Dir)
            {
                Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V3_DIR not set'
                return
            }
            # Search recursively - zip may extract into a subdirectory
            $found = Get-ChildItem -Path $script:v3Dir -Directory -Filter 'AppDeployToolkit' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            $found | Should -Not -BeNullOrEmpty
        }

        It 'V4 template contains Invoke-AppDeployToolkit.ps1' {
            if (-not $script:v4Dir)
            {
                Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V4_DIR not set'
                return
            }
            # Search recursively - zip may extract into a subdirectory
            $found = Get-ChildItem -Path $script:v4Dir -File -Filter 'Invoke-AppDeployToolkit.ps1' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            $found | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Deploy-WithPSADT-ToSCCM' {
    Context 'SCCM deployment using build output templates' {

        BeforeAll {
            $script:v3Dir = $env:PSADT_TEMPLATE_V3_DIR
            $script:v4Dir = $env:PSADT_TEMPLATE_V4_DIR
            $script:deployScript = Join-Path $PSScriptRoot 'Deploy-WithPSADT-ToSCCM.ps1'

            # Create a dummy MSI file if it does not exist (CI environments won't have the real installer)
            $script:workDir = 'C:\PSADT'
            $script:msiName = 'PatchMyPC-Publishing-Service-2.1.110.4 (2).msi'
            $script:msiPath = Join-Path $script:workDir $script:msiName
            $script:dummyCreated = $false
            if (-not (Test-Path $script:msiPath))
            {
                New-Item -ItemType Directory -Force -Path $script:workDir | Out-Null
                # Write a minimal valid MSI header (just needs to be a non-empty file;
                # Get-MSIProductCode will fail gracefully and return $null)
                [System.IO.File]::WriteAllBytes($script:msiPath, [byte[]](0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))
                $script:dummyCreated = $true
                Write-Verbose "  [setup] Created dummy MSI at: $($script:msiPath)"
            }
        }

        AfterAll {
            # Remove the dummy MSI if we created it, to keep the runner clean
            if ($script:dummyCreated -and (Test-Path $script:msiPath))
            {
                Remove-Item $script:msiPath -Force -ErrorAction SilentlyContinue
                Write-Verbose "  [teardown] Removed dummy MSI: $($script:msiPath)"
            }
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Deploy-WithPSADT-ToSCCM / SCCM deployment using build output templates'
            $script:CurrentTestMethod = $testInfo.Name
            Write-Verbose "[BeforeEach] TestClass: $($script:CurrentTestClass)"
            Write-Verbose "[BeforeEach] TestMethod: $($script:CurrentTestMethod)"
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest
        }

        It 'Deploy-WithPSADT-ToSCCM.ps1 script exists' {
            Test-Path $script:deployScript | Should -BeTrue
        }

        It 'Successfully runs SCCM deployment using build templates' {
            if (-not $script:v3Dir -or -not $script:v4Dir)
            {
                Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V3_DIR or PSADT_TEMPLATE_V4_DIR not set'
                return
            }
            { & $script:deployScript -TemplateV3Dir $script:v3Dir -TemplateV4Dir $script:v4Dir } | Should -Not -Throw
        }
    }
}

Describe 'WCP Package Preparation and SCCM Import' {
    Context 'Build WCP package from V4 template and import into SCCM' {

        BeforeAll {
            $script:v4Dir = $env:PSADT_TEMPLATE_V4_DIR
            $script:wcpSourceScript = Join-Path $PSScriptRoot 'WCP\Invoke-AppDeployToolkit.ps1'
            $script:wcpPackageDir = 'C:\PSADT\WCP'
            $script:wcpAppName = 'WinSCP (PSADT v4 WCP)'
            $script:wcpAppVendor = 'Martin Prikryl'
            $script:wcpAppVersion = '6.5.6'
            $script:wcpDTName = "WinSCP $script:wcpAppVersion (v4 WCP)"
            $script:wcpContentUNC = "\\$env:COMPUTERNAME\PSADT_Content$\WCP"

            $script:siteCode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Operations Management' -Name 'Site Code' -ErrorAction SilentlyContinue).'Site Code'
            $script:siteServer = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Provider Location' -ErrorAction SilentlyContinue).'Provider Location'
            if (-not $script:siteCode) { $script:siteCode = 'SQT' }
            if (-not $script:siteServer) { $script:siteServer = 'vm30028301.vm30028301dom.net' }

            $script:cmModulePath = @(
                'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1',
                'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
            ) | Where-Object { Test-Path $_ } | Select-Object -First 1

            if (-not $script:cmModulePath -and $env:SMS_ADMIN_UI_PATH)
            {
                $candidate = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
                if (Test-Path $candidate) { $script:cmModulePath = $candidate }
            }
        }

        AfterAll {
            if (Test-Path $script:wcpPackageDir)
            {
                Remove-Item $script:wcpPackageDir -Recurse -Force -ErrorAction SilentlyContinue
                Write-Verbose "  [teardown] Removed WCP package directory: $($script:wcpPackageDir)"
            }
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'WCP Package Preparation and SCCM Import / Build WCP package from V4 template and import into SCCM'
            $script:CurrentTestMethod = $testInfo.Name
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest
        }

        It 'Builds WCP package and imports into SCCM' {
            # ----------------------------------------------------------------
            # Step 1 - Verify prerequisites
            # ----------------------------------------------------------------
            if (-not $script:v4Dir)
            {
                Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V4_DIR not set'
                return
            }
            Test-Path $script:v4Dir | Should -BeTrue -Because 'V4 template directory must exist'
            Test-Path $script:wcpSourceScript | Should -BeTrue -Because 'WCP\Invoke-AppDeployToolkit.ps1 must exist'

            # ----------------------------------------------------------------
            # Step 2 - Copy V4 template to WCP package directory
            # ----------------------------------------------------------------
            Write-Verbose '[WCP] Step 2: Copying V4 template to WCP package directory...'
            if (Test-Path $script:wcpPackageDir)
            {
                Remove-Item $script:wcpPackageDir -Recurse -Force
            }
            Copy-Item -Path $script:v4Dir -Destination $script:wcpPackageDir -Recurse -Force
            Test-Path $script:wcpPackageDir | Should -BeTrue

            # ----------------------------------------------------------------
            # Step 3 - Replace Invoke-AppDeployToolkit.ps1 with WCP version
            # ----------------------------------------------------------------
            Write-Verbose '[WCP] Step 3: Replacing Invoke-AppDeployToolkit.ps1 with WCP version...'
            $destScript = Get-ChildItem -Path $script:wcpPackageDir -Filter 'Invoke-AppDeployToolkit.ps1' -Recurse -File |
            Select-Object -First 1
            $destScript | Should -Not -BeNullOrEmpty -Because 'Invoke-AppDeployToolkit.ps1 must exist in the copied V4 template'
            Copy-Item -Path $script:wcpSourceScript -Destination $destScript.FullName -Force
            $content = Get-Content -Path $destScript.FullName -Raw
            $content | Should -Match 'WinSCP'

            # ----------------------------------------------------------------
            # Step 4 - Copy WinSCP MSI into Files folder
            # ----------------------------------------------------------------
            Write-Verbose '[WCP] Step 4: Copying WinSCP MSI into Files folder...'
            $msiSource = 'C:\Tools\Intune\WinSCP\WinSCP-6.5.6.msi'
            if (-not (Test-Path $msiSource))
            {
                Write-Warning "[WCP] MSI not found at '$msiSource', skipping MSI copy step."
            }
            else
            {
                $filesDir = Join-Path $script:wcpPackageDir 'Files'
                if (-not (Test-Path $filesDir))
                {
                    New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
                }
                Copy-Item -Path $msiSource -Destination $filesDir -Force
                Test-Path (Join-Path $filesDir 'WinSCP-6.5.6.msi') | Should -BeTrue
            }

            # ----------------------------------------------------------------
            # Step 5 - Create SMB content share
            # ----------------------------------------------------------------
            Write-Verbose '[WCP] Step 5: Ensuring SMB content share exists...'
            if (-not $script:cmModulePath)
            {
                Set-ItResult -Skipped -Because 'ConfigurationManager module not available - skipping SCCM steps'
                return
            }
            $shareName = 'PSADT_Content$'
            if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue))
            {
                New-SmbShare -Name $shareName -Path 'C:\PSADT' -FullAccess 'Everyone' -Description 'PSADT SCCM Content Source' | Out-Null
            }
            Test-Path $script:wcpContentUNC | Should -BeTrue

            # ----------------------------------------------------------------
            # Step 6 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[WCP] Step 6: Importing WCP application into SCCM...'
            Import-Module $script:cmModulePath -ErrorAction Stop

            $origLoc = Get-Location
            try
            {
                if (-not (Get-PSDrive -Name $script:siteCode -ErrorAction SilentlyContinue))
                {
                    New-PSDrive -Name $script:siteCode -PSProvider CMSite -Root $script:siteServer | Out-Null
                }
                Set-Location "$($script:siteCode):\"

                # Remove existing application
                if (Get-CMApplication -Name $script:wcpAppName -ErrorAction SilentlyContinue)
                {
                    $existingDeps = Get-CMApplicationDeployment -Name $script:wcpAppName -ErrorAction SilentlyContinue
                    foreach ($dep in $existingDeps)
                    {
                        Remove-CMApplicationDeployment -Name $script:wcpAppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
                    }
                    Remove-CMApplication -Name $script:wcpAppName -Force
                    Start-Sleep -Seconds 2
                }

                New-CMApplication `
                    -Name            $script:wcpAppName `
                    -Publisher       $script:wcpAppVendor `
                    -SoftwareVersion $script:wcpAppVersion `
                    -LocalizedName   $script:wcpAppName `
                    -Description     "PSADT v4 WCP template - WinSCP $script:wcpAppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')" | Out-Null

                $installCmd = if (Test-Path (Join-Path $script:wcpPackageDir 'Invoke-AppDeployToolkit.exe'))
                {
                    'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent'
                }
                else
                {
                    'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install'
                }
                $uninstallCmd = if (Test-Path (Join-Path $script:wcpPackageDir 'Invoke-AppDeployToolkit.exe'))
                {
                    'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent'
                }
                else
                {
                    'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Uninstall'
                }

                $detectScript = @'
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$app = foreach ($root in $uninstallRoots)
{
    if (Test-Path $root)
    {
        Get-ChildItem -Path $root |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*WinSCP*' -and $_.DisplayVersion -eq '6.5.6' }
    }
}
if ($app) { exit 0 } else { exit 1 }
'@

                Add-CMScriptDeploymentType `
                    -ApplicationName           $script:wcpAppName `
                    -DeploymentTypeName        $script:wcpDTName `
                    -ContentLocation           $script:wcpContentUNC `
                    -InstallCommand            $installCmd `
                    -UninstallCommand          $uninstallCmd `
                    -ScriptLanguage            PowerShell `
                    -ScriptText                $detectScript `
                    -InstallationBehaviorType  InstallForSystem `
                    -LogonRequirementType      WhetherOrNotUserLoggedOn `
                    -RebootBehavior            BasedOnExitCode `
                    -SlowNetworkDeploymentMode Download `
                    -MaximumRuntimeMins        30 `
                    -EstimatedRuntimeMins      5 | Out-Null

                $dt = Get-CMDeploymentType -ApplicationName $script:wcpAppName -DeploymentTypeName $script:wcpDTName
                Add-CMDeploymentTypeReturnCode -InputObject $dt -ReturnCode 3010 -CodeType SoftReboot -Name 'Reboot Required' | Out-Null
                Add-CMDeploymentTypeReturnCode -InputObject $dt -ReturnCode 1641 -CodeType HardReboot -Name 'Reboot Initiated' | Out-Null

                $created = Get-CMApplication -Name $script:wcpAppName -ErrorAction SilentlyContinue
                $created | Should -Not -BeNullOrEmpty

                # ----------------------------------------------------------------
                # Step 7 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[WCP] Step 7: Triggering content distribution...'
                $dpGroups = Get-CMDistributionPointGroup -ErrorAction SilentlyContinue
                $dpList = Get-CMDistributionPoint -ErrorAction SilentlyContinue

                if ($dpGroups)
                {
                    foreach ($grp in $dpGroups)
                    {
                        Start-CMContentDistribution -ApplicationName $script:wcpAppName `
                            -DistributionPointGroupName $grp.Name -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                elseif ($dpList)
                {
                    foreach ($dp in $dpList)
                    {
                        Start-CMContentDistribution -ApplicationName $script:wcpAppName `
                            -DistributionPointName $dp.NetworkOSPath.TrimStart('\') -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                else
                {
                    Write-Warning '[WCP] No distribution points or DP groups found - content distribution skipped.'
                }
            }
            finally
            {
                Set-Location $origLoc
            }
        }
    }
}
