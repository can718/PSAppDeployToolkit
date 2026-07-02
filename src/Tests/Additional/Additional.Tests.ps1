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
    $script:TFResultByKey = @{}

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
            [string]$TestMethod,
            [string]$TestKey
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

        if (-not $script:TFResultByKey)
        {
            $script:TFResultByKey = @{}
        }
        if (-not [string]::IsNullOrWhiteSpace($TestKey))
        {
            [void]$script:TFResultByKey.Remove($TestKey)
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
            if (-not [string]::IsNullOrWhiteSpace($TestKey))
            {
                $script:TFResultByKey[$TestKey] = $result.Id
            }
            else
            {
                $script:TFCurrentResultId = $result.Id
            }
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
            [object]$TestResult,
            [string]$TestKey
        )
        $resultId = $null
        if (-not [string]::IsNullOrWhiteSpace($TestKey) -and $script:TFResultByKey -and $script:TFResultByKey.ContainsKey($TestKey))
        {
            $resultId = $script:TFResultByKey[$TestKey]
        }
        elseif ($script:TFCurrentResultId)
        {
            $resultId = $script:TFCurrentResultId
        }

        if (-not $script:TFReportingEnabled -or -not $resultId)
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
                -TestRunResultId $resultId `
                -Result $resultCode `
                -ErrorMessage $errorMsg
            Write-Verbose "[TerraForge] Updated result Id=$resultId -> code=$resultCode"
        }
        catch
        {
            Write-Warning "[TerraForge] Failed to update result Id=${resultId}: $($_.Exception.Message)"
        }
        finally
        {
            if (-not [string]::IsNullOrWhiteSpace($TestKey) -and $script:TFResultByKey)
            {
                [void]$script:TFResultByKey.Remove($TestKey)
            }
        }
    }

    function script:New-TFTestCaseKey
    {
        param (
            [string]$TestClass,
            [string]$TestMethod
        )

        $sessionSeed = if ($env:TEST_SESSION_ID) { $env:TEST_SESSION_ID } elseif ($env:TEST_RUN_ID) { $env:TEST_RUN_ID } else { "$PID" }
        $safeClass = if ([string]::IsNullOrWhiteSpace($TestClass)) { 'UnknownClass' } else { $TestClass }
        $safeMethod = if ([string]::IsNullOrWhiteSpace($TestMethod)) { 'UnknownMethod' } else { $TestMethod }
        return "$sessionSeed|$safeClass|$safeMethod|$([DateTime]::UtcNow.Ticks)"
    }

    function script:Get-PSADTParallelSafeSuffix
    {
        param (
            [int]$MaxLength = 24
        )

        $raw = if ($env:APP_TEST_SUFFIX)
        {
            $env:APP_TEST_SUFFIX
        }
        elseif ($env:TEST_SESSION_ID)
        {
            $env:TEST_SESSION_ID
        }
        elseif ($env:TEST_RUN_ID)
        {
            $env:TEST_RUN_ID
        }
        elseif ($env:GITHUB_RUN_ID)
        {
            $env:GITHUB_RUN_ID
        }
        else
        {
            $null
        }

        if ([string]::IsNullOrWhiteSpace($raw))
        {
            return ''
        }

        $safe = ($raw -replace '[^A-Za-z0-9-]', '-') -replace '-{2,}', '-'
        $safe = $safe.Trim('-')
        if ([string]::IsNullOrWhiteSpace($safe))
        {
            return ''
        }
        if ($safe.Length -gt $MaxLength)
        {
            $safe = $safe.Substring(0, $MaxLength)
        }

        return "-$safe"
    }

    $script:AdditionalHelpersPath = Join-Path $script:_tfScriptRoot 'Additional.Tests.Helpers.ps1'
    if (-not (Test-Path $script:AdditionalHelpersPath))
    {
        throw "Required helper file not found: $script:AdditionalHelpersPath"
    }
    . $script:AdditionalHelpersPath

}

# ---------------------------------------------------------------------------

Describe 'PSADT Build Template Validation' -Tag 'Validation' {
    Context 'Template paths from build output' {

        BeforeAll {
            $script:v3Dir = $env:PSADT_TEMPLATE_V3_DIR
            $script:v4Dir = $env:PSADT_TEMPLATE_V4_DIR
            $script:TemplateValidationPassed = $false
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'PSADT Build Template Validation / Template paths from build output'
            $script:CurrentTestMethod = $testInfo.Name
            $script:CurrentTestKey = New-TFTestCaseKey -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
            Write-Verbose "[BeforeEach] TestClass: $($script:CurrentTestClass)"
            Write-Verbose "[BeforeEach] TestMethod: $($script:CurrentTestMethod)"
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod -TestKey $script:CurrentTestKey
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest -TestKey $script:CurrentTestKey
        }

        It 'PSADT Build Template Validation' {
            # V3 and V4 environment variables must be set
            $script:v3Dir | Should -Not -BeNullOrEmpty -Because 'PSADT_TEMPLATE_V3_DIR environment variable must be set'
            $script:v4Dir | Should -Not -BeNullOrEmpty -Because 'PSADT_TEMPLATE_V4_DIR environment variable must be set'

            # V3 and V4 template directories must exist on disk
            Test-Path $script:v3Dir | Should -BeTrue -Because 'V3 template directory must exist on disk'
            Test-Path $script:v4Dir | Should -BeTrue -Because 'V4 template directory must exist on disk'

            # V3 template must contain AppDeployToolkit subfolder
            # Search recursively - zip may extract into a subdirectory
            $foundV3 = Get-ChildItem -Path $script:v3Dir -Directory -Filter 'AppDeployToolkit' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            $foundV3 | Should -Not -BeNullOrEmpty -Because 'V3 template must contain AppDeployToolkit subfolder'

            # V4 template must contain Invoke-AppDeployToolkit.ps1
            # Search recursively - zip may extract into a subdirectory
            $foundV4 = Get-ChildItem -Path $script:v4Dir -File -Filter 'Invoke-AppDeployToolkit.ps1' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            $foundV4 | Should -Not -BeNullOrEmpty -Because 'V4 template must contain Invoke-AppDeployToolkit.ps1'

            # Mark validation as passed for downstream tests within the same run.
            $script:TemplateValidationPassed = $true
        }
    }
}

Describe 'winSCP SCCM Deployment' -Tag 'WinSCP' {
    Context 'Build winSCP package from V4 template and deploy into SCCM' {

        BeforeAll {
            $ctx = New-PSADTAppTestContext `
                -SourceScriptRelativePath 'winSCP\Invoke-AppDeployToolkit.ps1' `
                -PackageDir 'C:\PSADT\winSCP' `
                -AppName 'WinSCP (PSADT v4 winSCP)' `
                -AppVendor 'Martin Prikryl' `
                -AppVersion '6.5.6' `
                -DeploymentTypeName 'WinSCP 6.5.6 (v4 winSCP)' `
                -ContentSubPath 'winSCP'

            $script:v4Dir = $ctx.V4Dir
            $script:winscpSourceScript = $ctx.SourceScript
            $script:winscpPackageDir = $ctx.PackageDir
            $script:winscpAppName = $ctx.AppName
            $script:winscpAppVendor = $ctx.AppVendor
            $script:winscpAppVersion = $ctx.AppVersion
            $script:winscpDTName = $ctx.DeploymentTypeName
            $script:winscpContentUNC = $ctx.ContentUNC
            $script:targetCollection = $ctx.TargetCollection
            $script:winscpInstallDeploySucceeded = $false
            $script:siteCode = $ctx.SiteCode
            $script:siteServer = $ctx.SiteServer
            $script:cmModulePath = $ctx.CmModulePath
        }

        AfterAll {
            # if (Test-Path $script:winscpPackageDir)
            # {
            #     Remove-Item $script:winscpPackageDir -Recurse -Force -ErrorAction SilentlyContinue
            #     Write-Verbose "  [teardown] Removed winSCP package directory: $($script:winscpPackageDir)"
            # }
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'winSCP Package Preparation and SCCM Deployment / Build winSCP package from V4 template and deploy into SCCM'
            $script:CurrentTestMethod = $testInfo.Name
            $script:CurrentTestKey = New-TFTestCaseKey -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod -TestKey $script:CurrentTestKey
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest -TestKey $script:CurrentTestKey
        }

        It '[MCM:WinSCP_Install] Install winSCP via SCCM application deployment' {
            Write-Information "::info::[winSCP] Step 0: Verifying template validation gate..."
            if (-not (Test-PSADTTemplateValidationGate))
            {
                Set-ItResult -Skipped -Because 'Template validation gate not satisfied. Run Validation first or set PSADT_TEMPLATE_VALIDATION_PASSED=true.'
                return
            }
            Write-Information "::info::[winSCP] Template validation gate satisfied." -InformationAction Continue

            # ----------------------------------------------------------------
            # Step 1 - Verify prerequisites
            # ----------------------------------------------------------------
            if (-not (Test-PSADTPackageBuildPrerequisites `
                        -TemplateDir $script:v4Dir `
                        -TemplateEnvName 'PSADT_TEMPLATE_V4_DIR' `
                        -SiteCode $script:siteCode `
                        -SiteServer $script:siteServer `
                        -SourceScriptLabel 'winSCP\Invoke-AppDeployToolkit.ps1' `
                        -LogPrefix 'winSCP' `
                        -UseInformationLogs))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 2 - Copy V4 template to winSCP package directory
            # ----------------------------------------------------------------
            Initialize-PSADTPackageDirectoryFromTemplateV4 -TemplateDir $script:v4Dir -PackageDir $script:winscpPackageDir -LogPrefix 'winSCP' -UseInformationLogs

            # # ----------------------------------------------------------------
            # # Step 3 - Replace Invoke-AppDeployToolkit.ps1 with winSCP version
            # # ----------------------------------------------------------------
            # $destScript = Update-PSADTPackageDeployScript `
            #     -PackageDir $script:winscpPackageDir `
            #     -SourceScript $script:winscpSourceScript `
            #     -ExpectedContentPattern 'WinSCP' `
            #     -LogPrefix 'winSCP' `
            #     -UseInformationLogs

            # # ----------------------------------------------------------------
            # # Step 4 - Copy WinSCP MSI into Files folder
            # # ----------------------------------------------------------------
            # $msiSource = 'C:\Tools\Intune\WinSCP\WinSCP-6.5.6.msi'
            # Copy-PSADTPackageInstallerToFiles `
            #     -DeployScriptPath $destScript.FullName `
            #     -InstallerSource $msiSource `
            #     -InstallerLabel 'MSI' `
            #     -LogPrefix 'winSCP' `
            #     -UseInformationLogs `
            #     -ExpectedFileName 'WinSCP-6.5.6.msi'

            # ----------------------------------------------------------------
            # Step 5 - Verify SMB content share and directories exist
            # ----------------------------------------------------------------
            if (-not (Assert-PSADTContentPathReady `
                        -CmModulePath $script:cmModulePath `
                        -PackageDir $script:winscpPackageDir `
                        -ContentUNC $script:winscpContentUNC `
                        -LogPrefix 'winSCP' `
                        -UseInformationLogs))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 6 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[winSCP] Step 6: Importing winSCP application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[winSCP] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
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
            Where-Object { $_.DisplayName -like '*WinSCP*' -and $_.DisplayVersion -like '6.5.6*' }
    }
}
if ($app) { Write-Host "Installed" }
'@

                New-PSADTApplicationWithDeploymentType `
                    -AppName $script:winscpAppName `
                    -Vendor $script:winscpAppVendor `
                    -Version $script:winscpAppVersion `
                    -DeploymentTypeName $script:winscpDTName `
                    -ContentUNC $script:winscpContentUNC `
                    -PackageDir $script:winscpPackageDir `
                    -DetectScript $detectScript `
                    -Description "PSADT v4 winSCP template - WinSCP $script:winscpAppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')"

                # ----------------------------------------------------------------
                # Step 7 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[winSCP] Step 7: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:winscpAppName -LogPrefix 'winSCP'

                # ----------------------------------------------------------------
                # Step 7b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[winSCP] Step 7b: Deploying application to collection '$($script:targetCollection)'..."
                New-PSADTRequiredDeployment -AppName $script:winscpAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'winSCP'

                # ----------------------------------------------------------------
                # Step 8 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[winSCP] Step 8: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:winscpAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                $script:winscpInstallDeploySucceeded = $true
            }
        }

        It '[MCM:WinSCP_Uninstall] Uninstall winSCP via SCCM application deployment' {
            if (-not $script:winscpInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'Installs winSCP via SCCM application deployment' did not complete successfully"
                return
            }

            if (-not $script:cmModulePath)
            {
                Set-ItResult -Skipped -Because 'ConfigurationManager module not available - skipping SCCM steps'
                return
            }

            if ([string]::IsNullOrWhiteSpace($script:siteCode) -or [string]::IsNullOrWhiteSpace($script:siteServer))
            {
                Set-ItResult -Skipped -Because 'SCCM siteCode or siteServer not configured (not an SCCM-managed environment)'
                return
            }

            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                $app = Get-CMApplication -Name $script:winscpAppName -ErrorAction SilentlyContinue
                $app | Should -Not -BeNullOrEmpty -Because 'winSCP application must exist before creating uninstall deployment'

                New-PSADTRequiredDeployment -AppName $script:winscpAppName -TargetCollection $script:targetCollection -DeployAction Uninstall -LogPrefix 'winSCP'

                # ----------------------------------------------------------------
                # Step 9 - Poll uninstall deployment status
                # ----------------------------------------------------------------
                Write-Information '[winSCP] Step 9: Polling uninstall deployment status...' -InformationAction Continue
                [void](Assert-PSADTDeploymentSummarySuccess -AppName $script:winscpAppName -SiteCode $script:siteCode -Label 'Uninstall deployment')
            }
        }
    }
}

Describe 'VLC SCCM Deployment' -Tag 'VLC' {
    Context 'Build VLC package from V4 template and deploy into SCCM' {

        BeforeAll {
            $ctx = New-PSADTAppTestContext `
                -SourceScriptRelativePath 'VLC\Invoke-AppDeployToolkit.ps1' `
                -SourceFolderRelativePath 'VLC' `
                -PackageDir 'C:\PSADT\VLC' `
                -AppName 'VLC media player (PSADT v4 VLC)' `
                -AppVendor 'VideoLAN' `
                -AppVersion '3.0.23' `
                -DeploymentTypeName 'VLC 3.0.23 (v4 VLC)' `
                -ContentSubPath 'VLC'

            $script:v4Dir = $ctx.V4Dir
            $script:vlcSourceScript = $ctx.SourceScript
            $script:vlcSourceFolder = $ctx.SourceFolder
            $script:vlcPackageDir = $ctx.PackageDir
            $script:vlcAppName = $ctx.AppName
            $script:vlcAppVendor = $ctx.AppVendor
            $script:vlcAppVersion = $ctx.AppVersion
            $script:vlcDTName = $ctx.DeploymentTypeName
            $script:vlcContentUNC = $ctx.ContentUNC
            $script:targetCollection = $ctx.TargetCollection
            $script:vlcInstallDeploySucceeded = $false
            $script:siteCode = $ctx.SiteCode
            $script:siteServer = $ctx.SiteServer
            $script:cmModulePath = $ctx.CmModulePath
        }

        AfterAll {
            # if (Test-Path $script:vlcPackageDir)
            # {
            #     Remove-Item $script:vlcPackageDir -Recurse -Force -ErrorAction SilentlyContinue
            #     Write-Verbose "  [teardown] Removed VLC package directory: $($script:vlcPackageDir)"
            # }
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'VLC Package Preparation and SCCM Import / Build VLC package from V4 template and import into SCCM'
            $script:CurrentTestMethod = $testInfo.Name
            $script:CurrentTestKey = New-TFTestCaseKey -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod -TestKey $script:CurrentTestKey
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest -TestKey $script:CurrentTestKey
        }

        It '[MCM:VLC_media_player_Install] Install VLC via SCCM application deployment' {
            if (-not (Test-PSADTTemplateValidationGate))
            {
                Set-ItResult -Skipped -Because 'Template validation gate not satisfied. Run Validation first or set PSADT_TEMPLATE_VALIDATION_PASSED=true.'
                return
            }

            # ----------------------------------------------------------------
            # Step 1 - Verify prerequisites
            # ----------------------------------------------------------------
            if (-not (Test-PSADTPackageBuildPrerequisites `
                        -TemplateDir $script:v4Dir `
                        -TemplateEnvName 'PSADT_TEMPLATE_V4_DIR' `
                        -SiteCode $script:siteCode `
                        -SiteServer $script:siteServer `
                        -SourceScriptLabel 'VLC\Invoke-AppDeployToolkit.ps1' `
                        -LogPrefix 'VLC'))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 2 - Copy V4 template to VLC package directory
            # ----------------------------------------------------------------
            Initialize-PSADTPackageDirectoryFromTemplateV4 -TemplateDir $script:v4Dir -PackageDir $script:vlcPackageDir -LogPrefix 'VLC'

            # # ----------------------------------------------------------------
            # # Step 3 - Replace Invoke-AppDeployToolkit.ps1 with VLC version
            # # ----------------------------------------------------------------
            # $destScript = Update-PSADTPackageDeployScript `
            #     -PackageDir $script:vlcPackageDir `
            #     -SourceScript $script:vlcSourceScript `
            #     -ExpectedContentPattern 'VLC' `
            #     -LogPrefix 'VLC' `
            #     -AdditionalContentSourceDir $script:vlcSourceFolder

            # # ----------------------------------------------------------------
            # # Step 4 - Copy VLC installer into Files folder
            # # ----------------------------------------------------------------
            # $installerSource = "C:\Tools\Intune\VLC\vlc-$($script:vlcAppVersion)-win64.exe"
            # Copy-PSADTPackageInstallerToFiles `
            #     -DeployScriptPath $destScript.FullName `
            #     -InstallerSource $installerSource `
            #     -InstallerLabel 'installer' `
            #     -LogPrefix 'VLC' `
            #     -ExpectedFileName "vlc-$($script:vlcAppVersion)-win64.exe"

            # ----------------------------------------------------------------
            # Step 5 - Verify SMB content share and directories exist
            # ----------------------------------------------------------------
            if (-not (Assert-PSADTContentPathReady `
                        -CmModulePath $script:cmModulePath `
                        -PackageDir $script:vlcPackageDir `
                        -ContentUNC $script:vlcContentUNC `
                        -LogPrefix 'VLC'))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 6 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[VLC] Step 6: Importing VLC application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[VLC] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
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
            Where-Object { $_.DisplayName -like '*VLC media player*' -and $_.DisplayVersion -like '3.0.23*' }
    }
}
if ($app) { Write-Host "Installed" }
'@

                New-PSADTApplicationWithDeploymentType `
                    -AppName $script:vlcAppName `
                    -Vendor $script:vlcAppVendor `
                    -Version $script:vlcAppVersion `
                    -DeploymentTypeName $script:vlcDTName `
                    -ContentUNC $script:vlcContentUNC `
                    -PackageDir $script:vlcPackageDir `
                    -DetectScript $detectScript `
                    -Description "PSADT v4 VLC template - VLC media player $script:vlcAppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')"

                # ----------------------------------------------------------------
                # Step 7 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[VLC] Step 7: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:vlcAppName -LogPrefix 'VLC'

                # ----------------------------------------------------------------
                # Step 7b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[VLC] Step 7b: Deploying application to collection '$($script:targetCollection)'..."
                New-PSADTRequiredDeployment -AppName $script:vlcAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'VLC'

                # ----------------------------------------------------------------
                # Step 8 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[VLC] Step 8: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:vlcAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                $script:vlcInstallDeploySucceeded = $true
            }
        }

        It '[MCM:VLC_media_player_Uninstall] Uninstall VLC via SCCM application deployment' {
            if (-not $script:vlcInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'Installs VLC via SCCM application deployment' did not complete successfully"
                return
            }

            if (-not $script:cmModulePath)
            {
                Set-ItResult -Skipped -Because 'ConfigurationManager module not available - skipping SCCM steps'
                return
            }

            if ([string]::IsNullOrWhiteSpace($script:siteCode) -or [string]::IsNullOrWhiteSpace($script:siteServer))
            {
                Set-ItResult -Skipped -Because 'SCCM siteCode or siteServer not configured (not an SCCM-managed environment)'
                return
            }

            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                $app = Get-CMApplication -Name $script:vlcAppName -ErrorAction SilentlyContinue
                $app | Should -Not -BeNullOrEmpty -Because 'VLC application must exist before creating uninstall deployment'

                New-PSADTRequiredDeployment -AppName $script:vlcAppName -TargetCollection $script:targetCollection -DeployAction Uninstall -LogPrefix 'VLC'

                # ----------------------------------------------------------------
                # Step 9 - Poll uninstall deployment status
                # ----------------------------------------------------------------
                Write-Information '[VLC] Step 9: Polling uninstall deployment status...' -InformationAction Continue
                [void](Assert-PSADTDeploymentSummarySuccess -AppName $script:vlcAppName -SiteCode $script:siteCode -Label 'Uninstall deployment')
            }
        }
    }
}

Describe 'Notepad++ SCCM Deployment' -Tag 'Notepad++' {
    Context 'Build Notepad++ package from V4 template and deploy into SCCM' {

        BeforeAll {
            $ctx = New-PSADTAppTestContext `
                -SourceScriptRelativePath 'Notepad++\Invoke-AppDeployToolkit.ps1' `
                -PackageDir 'C:\PSADT\NotepadPlusPlus' `
                -AppName 'Notepad++ (PSADT v4 Notepad++)' `
                -AppVendor 'Don HO don.h@free.fr' `
                -AppVersion '6.6.4' `
                -DeploymentTypeName 'Notepad++ 6.6.4 (v4 Notepad++)' `
                -ContentSubPath 'NotepadPlusPlus'

            $script:v4Dir = $ctx.V4Dir
            $script:notepadSourceScript = $ctx.SourceScript
            $script:notepadPackageDir = $ctx.PackageDir
            $script:notepadAppName = $ctx.AppName
            $script:notepadAppVendor = $ctx.AppVendor
            $script:notepadAppVersion = $ctx.AppVersion
            $script:notepadDTName = $ctx.DeploymentTypeName
            $script:notepadContentUNC = $ctx.ContentUNC
            $script:targetCollection = $ctx.TargetCollection
            $script:notepadInstallDeploySucceeded = $false
            $script:siteCode = $ctx.SiteCode
            $script:siteServer = $ctx.SiteServer
            $script:cmModulePath = $ctx.CmModulePath
        }

        AfterAll {
            # if (Test-Path $script:notepadPackageDir)
            # {
            #     Remove-Item $script:notepadPackageDir -Recurse -Force -ErrorAction SilentlyContinue
            #     Write-Verbose "  [teardown] Removed Notepad++ package directory: $($script:notepadPackageDir)"
            # }
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Notepad++ Package Preparation and SCCM Deployment / Build Notepad++ package from V4 template and deploy into SCCM'
            $script:CurrentTestMethod = $testInfo.Name
            $script:CurrentTestKey = New-TFTestCaseKey -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod -TestKey $script:CurrentTestKey
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest -TestKey $script:CurrentTestKey
        }

        It '[MCM:Notepad++_Install] Install Notepad++ via SCCM application deployment' {
            Write-Information '::info::[Notepad++] Step 0: Verifying template validation gate...'
            if (-not (Test-PSADTTemplateValidationGate))
            {
                Set-ItResult -Skipped -Because 'Template validation gate not satisfied. Run Validation first or set PSADT_TEMPLATE_VALIDATION_PASSED=true.'
                return
            }
            Write-Information '::info::[Notepad++] Template validation gate satisfied.' -InformationAction Continue

            # ----------------------------------------------------------------
            # Step 1 - Prepare local Notepad++ upgrade environment
            # ----------------------------------------------------------------
            $notepadEnvironment = Initialize-NotepadPlusPlusSccmEnvironment -LaunchLegacyProcess -LogPrefix 'Notepad++'
            # check if the environment is ready
            if (-not $notepadEnvironment)
            {
                Write-Information '::info::[Notepad++] Notepad++ environment not ready. Skipping test.' -InformationAction Continue
                Set-ItResult -Skipped -Because 'Notepad++ environment not ready. Check logs for details.'
                return
            }
            # ----------------------------------------------------------------
            # Step 2 - Verify prerequisites
            # ----------------------------------------------------------------
            if (-not (Test-PSADTPackageBuildPrerequisites `
                        -TemplateDir $script:v4Dir `
                        -TemplateEnvName 'PSADT_TEMPLATE_V4_DIR' `
                        -SiteCode $script:siteCode `
                        -SiteServer $script:siteServer `
                        -SourceScriptLabel 'Notepad++\Invoke-AppDeployToolkit.ps1' `
                        -LogPrefix 'Notepad++' `
                        -UseInformationLogs))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 3 - Copy V4 template to Notepad++ package directory
            # ----------------------------------------------------------------
            Initialize-PSADTPackageDirectoryFromTemplateV4 -TemplateDir $script:v4Dir -PackageDir $script:notepadPackageDir -LogPrefix 'Notepad++' -UseInformationLogs

            # # ----------------------------------------------------------------
            # # Step 4 - Replace Invoke-AppDeployToolkit.ps1 with Notepad++ version
            # # ----------------------------------------------------------------
            # $destScript = Update-PSADTPackageDeployScript `
            #     -PackageDir $script:notepadPackageDir `
            #     -SourceScript $script:notepadSourceScript `
            #     -ExpectedContentPattern 'Notepad\+\+' `
            #     -LogPrefix 'Notepad++' `
            #     -UseInformationLogs

            # # ----------------------------------------------------------------
            # # Step 5 - Copy Notepad++ installer into Files folder
            # # ----------------------------------------------------------------
            # Copy-PSADTPackageInstallerToFiles `
            #     -DeployScriptPath $destScript.FullName `
            #     -InstallerSource $notepadEnvironment.TargetInstallerPath `
            #     -InstallerLabel 'installer' `
            #     -LogPrefix 'Notepad++' `
            #     -UseInformationLogs `
            #     -ExpectedFileName 'npp.6.6.4.Installer.exe'

            # ----------------------------------------------------------------
            # Step 6 - Verify SMB content share and directories exist
            # ----------------------------------------------------------------
            if (-not (Assert-PSADTContentPathReady `
                        -CmModulePath $script:cmModulePath `
                        -PackageDir $script:notepadPackageDir `
                        -ContentUNC $script:notepadContentUNC `
                        -LogPrefix 'Notepad++' `
                        -UseInformationLogs))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 7 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[Notepad++] Step 7: Importing Notepad++ application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[Notepad++] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
                $detectScript = @'
$uninstallKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'
if (Test-Path $uninstallKey)
{
    $app = Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue
    if ($app.DisplayVersion -like '6.6.4*')
    {
        Write-Host "Installed"
    }
}
'@

                New-PSADTApplicationWithDeploymentType `
                    -AppName $script:notepadAppName `
                    -Vendor $script:notepadAppVendor `
                    -Version $script:notepadAppVersion `
                    -DeploymentTypeName $script:notepadDTName `
                    -ContentUNC $script:notepadContentUNC `
                    -PackageDir $script:notepadPackageDir `
                    -DetectScript $detectScript `
                    -Description "PSADT v4 Notepad++ template - Notepad++ $script:notepadAppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')"

                # ----------------------------------------------------------------
                # Step 8 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[Notepad++] Step 8: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:notepadAppName -LogPrefix 'Notepad++'

                # ----------------------------------------------------------------
                # Step 8b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[Notepad++] Step 8b: Deploying application to collection '$($script:targetCollection)'..."
                New-PSADTRequiredDeployment -AppName $script:notepadAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'Notepad++'

                # ----------------------------------------------------------------
                # Step 9 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[Notepad++] Step 9: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:notepadAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                $script:notepadInstallDeploySucceeded = $true
                #---------------------------------------------------------------
                # Step 10 - Check version of installed Notepad++
                #---------------------------------------------------------------
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
        }
    }
}

Describe 'DigiExam SCCM Deployment using V3 template and MSI installer' -Tag 'DigiExam' {
    Context 'Build DigiExam package from V3 template and deploy into SCCM' {

        BeforeAll {
            $ctx = New-PSADTAppTestContext `
                -SourceScriptRelativePath '..\V3\DigiExam\Invoke-AppDeployToolkit.ps1' `
                -PackageDir 'C:\PSADT\DigiExam' `
                -AppName 'Digiexam (PSADT v3 Digiexam)' `
                -AppVendor 'DigiExam' `
                -AppVersion '26.1.24' `
                -DeploymentTypeName 'Digiexam 26.1.24 (v3 Digiexam)' `
                -ContentSubPath 'DigiExam'

            $script:v3Dir = $ctx.V3Dir
            $script:digiExamSourceScript = $ctx.SourceScript
            $script:digiExamPackageDir = $ctx.PackageDir
            $script:digiExamAppName = $ctx.AppName
            $script:digiExamAppVendor = $ctx.AppVendor
            $script:digiExamAppVersion = $ctx.AppVersion
            $script:digiExamDTName = $ctx.DeploymentTypeName
            $script:digiExamContentUNC = $ctx.ContentUNC
            $script:targetCollection = $ctx.TargetCollection
            $script:digiExamInstallDeploySucceeded = $false
            $script:siteCode = $ctx.SiteCode
            $script:siteServer = $ctx.SiteServer
            $script:cmModulePath = $ctx.CmModulePath
        }

        AfterAll {
            # if (Test-Path $script:digiExamPackageDir)
            # {
            #     Remove-Item $script:digiExamPackageDir -Recurse -Force -ErrorAction SilentlyContinue
            #     Write-Verbose "  [teardown] Removed DigiExam package directory: $($script:digiExamPackageDir)"
            # }
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'DigiExam Package Preparation and SCCM Deployment / Build DigiExam package from V3 template and deploy into SCCM'
            $script:CurrentTestMethod = $testInfo.Name
            $script:CurrentTestKey = New-TFTestCaseKey -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod -TestKey $script:CurrentTestKey
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest -TestKey $script:CurrentTestKey
        }

        It '[MCM:Digiexam_Install] [V3] Install DigiExam via SCCM application deployment' {
            Write-Information "::info::[DigiExam] Step 0: Verifying template validation gate..."
            if (-not (Test-PSADTTemplateValidationGate))
            {
                Set-ItResult -Skipped -Because 'Template validation gate not satisfied. Run Validation first or set PSADT_TEMPLATE_VALIDATION_PASSED=true.'
                return
            }
            Write-Information "::info::[DigiExam] Template validation gate satisfied." -InformationAction Continue

            # ----------------------------------------------------------------
            # Step 1 - Verify prerequisites
            # ----------------------------------------------------------------
            if (-not (Test-PSADTPackageBuildPrerequisites `
                        -TemplateDir $script:v3Dir `
                        -TemplateEnvName 'PSADT_TEMPLATE_V3_DIR' `
                        -SiteCode $script:siteCode `
                        -SiteServer $script:siteServer `
                        -SourceScriptLabel 'DigiExam\Invoke-AppDeployToolkit.ps1' `
                        -LogPrefix 'DigiExam' `
                        -UseInformationLogs))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 2 - Copy V3 template to DigiExam package directory
            # ----------------------------------------------------------------
            Initialize-PSADTPackageDirectoryFromTemplate -TemplateDir $script:v3Dir -PackageDir $script:digiExamPackageDir -LogPrefix 'DigiExam' -UseInformationLogs

            # ----------------------------------------------------------------
            # Step 3 - Replace Invoke-AppDeployToolkit.ps1 with DigiExam version
            # ----------------------------------------------------------------
            $destScript = Update-PSADTPackageDeployScript `
                -PackageDir $script:digiExamPackageDir `
                -SourceScript $script:digiExamSourceScript `
                -ExpectedContentPattern 'DigiExam' `
                -LogPrefix 'DigiExam' `
                -UseInformationLogs

            # ----------------------------------------------------------------
            # Step 4 - Copy DigiExam MSI into Files folder
            # ----------------------------------------------------------------
            $msiSource = 'C:\Tools\Intune\DigiExam\Digiexam_26.1.24_x64_en-US.msi'
            Copy-PSADTPackageInstallerToFiles `
                -DeployScriptPath $destScript.FullName `
                -InstallerSource $msiSource `
                -InstallerLabel 'MSI' `
                -LogPrefix 'DigiExam' `
                -UseInformationLogs `
                -ExpectedFileName 'Digiexam_26.1.24_x64_en-US.msi'

            # ----------------------------------------------------------------
            # Step 5 - Verify SMB content share and directories exist
            # ----------------------------------------------------------------
            if (-not (Assert-PSADTContentPathReady `
                        -CmModulePath $script:cmModulePath `
                        -PackageDir $script:digiExamPackageDir `
                        -ContentUNC $script:digiExamContentUNC `
                        -LogPrefix 'DigiExam' `
                        -UseInformationLogs))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 6 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[DigiExam] Step 6: Importing DigiExam application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[DigiExam] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
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
            Where-Object { $_.DisplayName -like '*DigiExam*' -and $_.DisplayVersion -like '26.1.24*' }
    }
}
if ($app) { Write-Host "Installed" }
'@

                New-PSADTApplicationWithDeploymentType `
                    -AppName $script:digiExamAppName `
                    -Vendor $script:digiExamAppVendor `
                    -Version $script:digiExamAppVersion `
                    -DeploymentTypeName $script:digiExamDTName `
                    -ContentUNC $script:digiExamContentUNC `
                    -PackageDir $script:digiExamPackageDir `
                    -DetectScript $detectScript `
                    -Description "PSADT v3 DigiExam template - DigiExam $script:digiExamAppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')"

                # ----------------------------------------------------------------
                # Step 7 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[DigiExam] Step 7: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:digiExamAppName -LogPrefix 'DigiExam'

                # ----------------------------------------------------------------
                # Step 7b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[DigiExam] Step 7b: Deploying application to collection '$($script:targetCollection)'..."
                New-PSADTRequiredDeployment -AppName $script:digiExamAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'DigiExam'

                # ----------------------------------------------------------------
                # Step 8 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[DigiExam] Step 8: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:digiExamAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                $script:digiExamInstallDeploySucceeded = $true
            }
        }

        It '[MCM:Digiexam_Uninstall] [V3] Uninstall DigiExam via SCCM application deployment' {
            if (-not $script:digiExamInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'Installs DigiExam via SCCM application deployment' did not complete successfully"
                return
            }

            if (-not $script:cmModulePath)
            {
                Set-ItResult -Skipped -Because 'ConfigurationManager module not available - skipping SCCM steps'
                return
            }

            if ([string]::IsNullOrWhiteSpace($script:siteCode) -or [string]::IsNullOrWhiteSpace($script:siteServer))
            {
                Set-ItResult -Skipped -Because 'SCCM siteCode or siteServer not configured (not an SCCM-managed environment)'
                return
            }

            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                $app = Get-CMApplication -Name $script:digiExamAppName -ErrorAction SilentlyContinue
                $app | Should -Not -BeNullOrEmpty -Because 'DigiExam application must exist before creating uninstall deployment'

                New-PSADTRequiredDeployment -AppName $script:digiExamAppName -TargetCollection $script:targetCollection -DeployAction Uninstall -LogPrefix 'DigiExam'

                # ----------------------------------------------------------------
                # Step 9 - Poll uninstall deployment status
                # ----------------------------------------------------------------
                Write-Information '[DigiExam] Step 9: Polling uninstall deployment status...' -InformationAction Continue
                [void](Assert-PSADTDeploymentSummarySuccess -AppName $script:digiExamAppName -SiteCode $script:siteCode -Label 'Uninstall deployment')
            }
        }
    }
}

Describe 'Everything SCCM Deployment using V3 template and EXE installer' -Tag 'Everything' {
    Context 'Build Everything package from V3 template and deploy into SCCM' {

        BeforeAll {
            $ctx = New-PSADTAppTestContext `
                -SourceScriptRelativePath '..\V3\Everything\Deploy-Application.ps1' `
                -PackageDir 'C:\PSADT\Everything' `
                -AppName 'Everything (PSADT v3 Everything)' `
                -AppVendor 'voidtools' `
                -AppVersion '1.4.1.1032' `
                -DeploymentTypeName 'Everything 1.4.1.1032 (v3 Everything)' `
                -ContentSubPath 'Everything'

            $script:v3Dir = $ctx.V3Dir
            $script:everythingSourceScript = $ctx.SourceScript
            $script:everythingPackageDir = $ctx.PackageDir
            $script:everythingAppName = $ctx.AppName
            $script:everythingAppVendor = $ctx.AppVendor
            $script:everythingAppVersion = $ctx.AppVersion
            $script:everythingDTName = $ctx.DeploymentTypeName
            $script:everythingContentUNC = $ctx.ContentUNC
            $script:targetCollection = $ctx.TargetCollection
            $script:everythingInstallDeploySucceeded = $false
            $script:siteCode = $ctx.SiteCode
            $script:siteServer = $ctx.SiteServer
            $script:cmModulePath = $ctx.CmModulePath
        }

        AfterAll {
            # if (Test-Path $script:everythingPackageDir)
            # {
            #     Remove-Item $script:everythingPackageDir -Recurse -Force -ErrorAction SilentlyContinue
            #     Write-Verbose "  [teardown] Removed Everything package directory: $($script:everythingPackageDir)"
            # }
        }

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Everything Package Preparation and SCCM Deployment / Build Everything package from V3 template and deploy into SCCM'
            $script:CurrentTestMethod = $testInfo.Name
            $script:CurrentTestKey = New-TFTestCaseKey -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod -TestKey $script:CurrentTestKey
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest -TestKey $script:CurrentTestKey
        }

        It '[MCM:Everything_Install] [V3] Install Everything via SCCM application deployment' {
            Write-Information "::info::[Everything] Step 0: Verifying template validation gate..."
            if (-not (Test-PSADTTemplateValidationGate))
            {
                Set-ItResult -Skipped -Because 'Template validation gate not satisfied. Run Validation first or set PSADT_TEMPLATE_VALIDATION_PASSED=true.'
                return
            }
            Write-Information "::info::[Everything] Template validation gate satisfied." -InformationAction Continue

            # ----------------------------------------------------------------
            # Step 1 - Verify prerequisites
            # ----------------------------------------------------------------
            if (-not (Test-PSADTPackageBuildPrerequisites `
                        -TemplateDir $script:v3Dir `
                        -TemplateEnvName 'PSADT_TEMPLATE_V3_DIR' `
                        -SiteCode $script:siteCode `
                        -SiteServer $script:siteServer `
                        -SourceScriptLabel 'Everything\Deploy-Application.ps1' `
                        -LogPrefix 'Everything' `
                        -UseInformationLogs))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 2 - Copy V3 template to Everything package directory
            # ----------------------------------------------------------------
            Initialize-PSADTPackageDirectoryFromTemplate -TemplateDir $script:v3Dir -PackageDir $script:everythingPackageDir -LogPrefix 'Everything' -UseInformationLogs

            # ----------------------------------------------------------------
            # Step 3 - Replace Deploy-Application.ps1 with Everything version
            # ----------------------------------------------------------------
            $destScript = Update-PSADTPackageDeployScript `
                -PackageDir $script:everythingPackageDir `
                -SourceScript $script:everythingSourceScript `
                -ExpectedContentPattern 'Everything' `
                -LogPrefix 'Everything' `
                -UseInformationLogs

            # ----------------------------------------------------------------
            # Step 4 - Copy Everything EXE into Files folder
            # ----------------------------------------------------------------
            $exeSource = 'C:\Tools\Intune\Everything-1.4.1.1032.x64-Setup.exe'
            Copy-PSADTPackageInstallerToFiles `
                -DeployScriptPath $destScript.FullName `
                -InstallerSource $exeSource `
                -InstallerLabel 'EXE' `
                -LogPrefix 'Everything' `
                -UseInformationLogs `
                -ExpectedFileName 'Everything-1.4.1.1032.x64-Setup.exe'

            # ----------------------------------------------------------------
            # Step 5 - Verify SMB content share and directories exist
            # ----------------------------------------------------------------
            if (-not (Assert-PSADTContentPathReady `
                        -CmModulePath $script:cmModulePath `
                        -PackageDir $script:everythingPackageDir `
                        -ContentUNC $script:everythingContentUNC `
                        -LogPrefix 'Everything' `
                        -UseInformationLogs))
            {
                return
            }

            # ----------------------------------------------------------------
            # Step 6 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[Everything] Step 6: Importing Everything application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[Everything] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
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
            Where-Object { $_.DisplayName -like '*Everything*' -and $_.DisplayVersion -like '1.4.1.1032*' }
    }
}
if ($app) { Write-Host "Installed" }
'@

                New-PSADTApplicationWithDeploymentType `
                    -AppName $script:everythingAppName `
                    -Vendor $script:everythingAppVendor `
                    -Version $script:everythingAppVersion `
                    -DeploymentTypeName $script:everythingDTName `
                    -ContentUNC $script:everythingContentUNC `
                    -PackageDir $script:everythingPackageDir `
                    -DetectScript $detectScript `
                    -Description "PSADT v3 Everything template - Everything $script:everythingAppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')"

                # ----------------------------------------------------------------
                # Step 7 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[Everything] Step 7: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:everythingAppName -LogPrefix 'Everything'

                # ----------------------------------------------------------------
                # Step 7b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[Everything] Step 7b: Deploying application to collection '$($script:targetCollection)'..."
                New-PSADTRequiredDeployment -AppName $script:everythingAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'Everything'

                # ----------------------------------------------------------------
                # Step 8 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[Everything] Step 8: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:everythingAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                $script:everythingInstallDeploySucceeded = $true
            }
        }

        It '[MCM:Everything_Uninstall] [V3] Uninstall Everything via SCCM application deployment' {
            if (-not $script:everythingInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'Installs Everything via SCCM application deployment' did not complete successfully"
                return
            }

            if (-not $script:cmModulePath)
            {
                Set-ItResult -Skipped -Because 'ConfigurationManager module not available - skipping SCCM steps'
                return
            }

            if ([string]::IsNullOrWhiteSpace($script:siteCode) -or [string]::IsNullOrWhiteSpace($script:siteServer))
            {
                Set-ItResult -Skipped -Because 'SCCM siteCode or siteServer not configured (not an SCCM-managed environment)'
                return
            }

            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                $app = Get-CMApplication -Name $script:everythingAppName -ErrorAction SilentlyContinue
                $app | Should -Not -BeNullOrEmpty -Because 'Everything application must exist before creating uninstall deployment'

                New-PSADTRequiredDeployment -AppName $script:everythingAppName -TargetCollection $script:targetCollection -DeployAction Uninstall -LogPrefix 'Everything'

                # ----------------------------------------------------------------
                # Step 9 - Poll uninstall deployment status
                # ----------------------------------------------------------------
                Write-Information '[Everything] Step 9: Polling uninstall deployment status...' -InformationAction Continue
                [void](Assert-PSADTDeploymentSummarySuccess -AppName $script:everythingAppName -SiteCode $script:siteCode -Label 'Uninstall deployment')
            }
        }
    }
}