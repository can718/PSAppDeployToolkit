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

    $script:SharedTestAppsPath = Join-Path $script:_tfScriptRoot '..\_Shared\TestApps.ps1'
    if (-not (Test-Path $script:SharedTestAppsPath))
    {
        throw "Required shared app configuration file not found: $script:SharedTestAppsPath"
    }
    $script:SharedTestApps = & $script:SharedTestAppsPath
    function script:Resolve-SharedPSADTAppParameters
    {
        param(
            [Parameter(Mandatory = $true)]
            [hashtable]$App
        )

        $resolved = @{}
        foreach ($entry in $App.GetEnumerator())
        {
            $resolved[$entry.Key] = $entry.Value
        }

        $templateToken = if ($resolved.TemplateVersion) { $resolved.TemplateVersion.ToString().TrimStart('V', 'v') } else { '' }
        $appName = if ($resolved.Name) { $resolved.Name } else { '' }

        if (-not $resolved.ContentSubPath -and $resolved.AppFolderName)
        {
            $resolved.ContentSubPath = $resolved.AppFolderName
        }

        if (-not $resolved.PackageDir -and $resolved.ContentSubPath)
        {
            $resolved.PackageDir = "C:\PSADT\$($resolved.ContentSubPath)"
        }

        if (-not $resolved.SourceScriptRelativePath -and $resolved.TemplateVersion -and $resolved.AppFolderName)
        {
            if ($resolved.TemplateVersion -eq 'V3')
            {
                $resolved.SourceScriptRelativePath = "..\V3\$($resolved.AppFolderName)\Deploy-Application.ps1"
            }
            else
            {
                $resolved.SourceScriptRelativePath = "$($resolved.AppFolderName)\Invoke-AppDeployToolkit.ps1"
            }
        }

        if (-not $resolved.AppName -and $appName -and $templateToken)
        {
            $resolved.AppName = "$appName (PSADT v$templateToken $appName)"
        }

        if (-not $resolved.DeploymentTypeName -and $appName -and $resolved.AppVersion -and $templateToken)
        {
            $resolved.DeploymentTypeName = "$appName $($resolved.AppVersion) (v$templateToken $appName)"
        }

        if (-not $resolved.DescriptionTemplate -and $appName -and $templateToken)
        {
            $resolved.DescriptionTemplate = "PSADT v$templateToken $appName template - $appName {0} - auto-created {1}"
        }

        if (-not $resolved.InstallCmd)
        {
            throw "InstallCmd must be explicitly defined for app '$appName'. Found: $($resolved.InstallCmd | Out-String)"
        }

        if (-not $resolved.UninstallCmd)
        {
            throw "UninstallCmd must be explicitly defined for app '$appName'. Found: $($resolved.UninstallCmd | Out-String)"
        }

        if (-not $resolved.DetectScript)
        {
            $displayNamePattern = if ($resolved.RegDisplayName) { "*$($resolved.RegDisplayName)*" } else { "*$appName*" }
            $versionPattern = if ($resolved.AppVersion) { "$($resolved.AppVersion)*" } elseif ($resolved.RegVersionValue) { "$($resolved.RegVersionValue)*" } else { '*' }
            $resolved.DetectScript = @"
`$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
`$app = foreach (`$root in `$uninstallRoots)
{
    if (Test-Path `$root)
    {
        Get-ChildItem -Path `$root |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { `$_.DisplayName -like '$displayNamePattern' -and `$_.DisplayVersion -like '$versionPattern' }
    }
}
if (`$app) { Write-Host "Installed" }
"@
        }

        return $resolved
    }

    function script:Get-SharedPSADTAppParameters
    {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name
        )

        $app = $script:SharedTestApps | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if (-not $app)
        {
            throw "Shared app configuration not found for '$Name'."
        }
        return (Resolve-SharedPSADTAppParameters -App $app)
    }

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
            $winSCPParameters = Get-SharedPSADTAppParameters -Name 'WinSCP'
            $ctx = New-PSADTAppTestContextSafe -Parameters $winSCPParameters -LogPrefix 'winSCP'

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
            $script:winscpDetectScript = $winSCPParameters.DetectScript
            $script:winscpDescriptionTemplate = $winSCPParameters.DescriptionTemplate
            $script:winscpInstallCmd = $winSCPParameters.InstallCmd
            $script:winscpUninstallCmd = $winSCPParameters.UninstallCmd
            $script:winscpLogValidationApp = New-PSADTLogValidationAppConfig -TemplateVersion 'V4' -AppFolderName 'WinSCP' -Name 'WinSCP'
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

        It '[MCM:WinSCP_Install] [v4] winSCP should installed' {
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

            # ----------------------------------------------------------------
            # Step 3 - Verify SMB content share and directories exist
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
            # Step 4 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[winSCP] Step 4: Importing winSCP application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[winSCP] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
                $createAppParams = @{
                    AppName            = $script:winscpAppName
                    Vendor             = $script:winscpAppVendor
                    Version            = $script:winscpAppVersion
                    DeploymentTypeName = $script:winscpDTName
                    ContentUNC         = $script:winscpContentUNC
                    PackageDir         = $script:winscpPackageDir
                    DetectScript       = $script:winscpDetectScript
                    Description        = ($script:winscpDescriptionTemplate -f $script:winscpAppVersion, (Get-Date -Format 'yyyy-MM-dd'))
                }
                if (-not [string]::IsNullOrWhiteSpace($script:winscpInstallCmd))
                {
                    $createAppParams.InstallCmd = $script:winscpInstallCmd
                }
                if (-not [string]::IsNullOrWhiteSpace($script:winscpUninstallCmd))
                {
                    $createAppParams.UninstallCmd = $script:winscpUninstallCmd
                }
                Invoke-PSADTApplicationWithDeploymentTypeSafe -Parameters $createAppParams -LogPrefix 'winSCP'

                # ----------------------------------------------------------------
                # Step 5 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[winSCP] Step 5: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:winscpAppName -LogPrefix 'winSCP'

                # ----------------------------------------------------------------
                # Step 6 - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[winSCP] Step 6: Deploying application to collection '$($script:targetCollection)'..."
                New-PSADTRequiredDeployment -AppName $script:winscpAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'winSCP'

                # ----------------------------------------------------------------
                # Step 7 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[winSCP] Step 7: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:winscpAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                Assert-PSADTDeploymentLogValidation -App $script:winscpLogValidationApp -DeploymentType 'Install' -LogPrefix 'winSCP'
                $script:winscpInstallDeploySucceeded = $true
            }
        }

        It '[MCM:WinSCP_Uninstall] [v4] winSCP should uninstalled' {
            if (-not $script:winscpInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'winSCP should installed' did not complete successfully"
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
                # Step 8 - Poll uninstall deployment status
                # ----------------------------------------------------------------
                Write-Information '[winSCP] Step 8: Polling uninstall deployment status...' -InformationAction Continue
                [void](Assert-PSADTDeploymentSummarySuccess -AppName $script:winscpAppName -SiteCode $script:siteCode -Label 'Step 8: Uninstall deployment')
                Assert-PSADTDeploymentLogValidation -App $script:winscpLogValidationApp -DeploymentType 'Uninstall' -LogPrefix 'winSCP'
            }
        }
    }
}

Describe 'VLC SCCM Deployment' -Tag 'VLC' {
    Context 'Build VLC package from V4 template and deploy into SCCM' {

        BeforeAll {
            $vlcParameters = Get-SharedPSADTAppParameters -Name 'VLC'
            $ctx = New-PSADTAppTestContextSafe -Parameters $vlcParameters -LogPrefix 'VLC'

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
            $script:vlcDetectScript = $vlcParameters.DetectScript
            $script:vlcDescriptionTemplate = $vlcParameters.DescriptionTemplate
            $script:vlcInstallCmd = $vlcParameters.InstallCmd
            $script:vlcUninstallCmd = $vlcParameters.UninstallCmd
            $script:vlcLogValidationApp = New-PSADTLogValidationAppConfig -TemplateVersion 'V4' -AppFolderName 'VLC' -Name 'VLC'
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

        It '[MCM:VLC_media_player_Install] [v4] VLC should installed' {
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

            # ----------------------------------------------------------------
            # Step 3 - Verify SMB content share and directories exist
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
            # Step 4 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[VLC] Step 4: Importing VLC application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[VLC] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
                $createAppParams = @{
                    AppName            = $script:vlcAppName
                    Vendor             = $script:vlcAppVendor
                    Version            = $script:vlcAppVersion
                    DeploymentTypeName = $script:vlcDTName
                    ContentUNC         = $script:vlcContentUNC
                    PackageDir         = $script:vlcPackageDir
                    DetectScript       = $script:vlcDetectScript
                    Description        = ($script:vlcDescriptionTemplate -f $script:vlcAppVersion, (Get-Date -Format 'yyyy-MM-dd'))
                }
                if (-not [string]::IsNullOrWhiteSpace($script:vlcInstallCmd))
                {
                    $createAppParams.InstallCmd = $script:vlcInstallCmd
                }
                if (-not [string]::IsNullOrWhiteSpace($script:vlcUninstallCmd))
                {
                    $createAppParams.UninstallCmd = $script:vlcUninstallCmd
                }
                Invoke-PSADTApplicationWithDeploymentTypeSafe -Parameters $createAppParams -LogPrefix 'VLC'

                # ----------------------------------------------------------------
                # Step 5 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[VLC] Step 5: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:vlcAppName -LogPrefix 'VLC'

                # ----------------------------------------------------------------
                # Step 5b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[VLC] Step 5b: Deploying application to collection '$($script:targetCollection)'..."
                New-PSADTRequiredDeployment -AppName $script:vlcAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'VLC'

                # ----------------------------------------------------------------
                # Step 6 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[VLC] Step 6: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:vlcAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                Assert-PSADTDeploymentLogValidation -App $script:vlcLogValidationApp -DeploymentType 'Install' -LogPrefix 'VLC'
                $script:vlcInstallDeploySucceeded = $true
            }
        }

        It '[MCM:VLC_media_player_Uninstall] [v4] VLC should uninstalled' {
            if (-not $script:vlcInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'VLC should installed' did not complete successfully"
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
                Assert-PSADTDeploymentLogValidation -App $script:vlcLogValidationApp -DeploymentType 'Uninstall' -LogPrefix 'VLC'
            }
        }
    }
}

Describe 'Notepad++ SCCM Deployment' -Tag 'Notepad++' {
    Context 'Build Notepad++ package from V4 template and deploy into SCCM' {

        BeforeAll {
            $notepadParameters = Get-SharedPSADTAppParameters -Name 'Notepad++'
            $ctx = New-PSADTAppTestContextSafe -Parameters $notepadParameters -LogPrefix 'Notepad++'

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
            $script:notepadDetectScript = $notepadParameters.DetectScript
            $script:notepadDescriptionTemplate = $notepadParameters.DescriptionTemplate
            $script:notepadInstallCmd = $notepadParameters.InstallCmd
            $script:notepadUninstallCmd = $notepadParameters.UninstallCmd
            $script:notepadVersionValidationApp = $notepadParameters
            $script:notepadLogValidationApp = New-PSADTLogValidationAppConfig -TemplateVersion 'V4' -AppFolderName 'Notepad++' -Name 'Notepad++'
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

        It '[MCM:Notepad++_Install_FirstDeferral] [v4] Notepad++ first install attempt should defer when app is open' {
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

            # ----------------------------------------------------------------
            # Step 4 - Verify SMB content share and directories exist
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
            # Step 5 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[Notepad++] Step 5: Importing Notepad++ application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[Notepad++] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
                $createAppParams = @{
                    AppName            = $script:notepadAppName
                    Vendor             = $script:notepadAppVendor
                    Version            = $script:notepadAppVersion
                    DeploymentTypeName = $script:notepadDTName
                    ContentUNC         = $script:notepadContentUNC
                    PackageDir         = $script:notepadPackageDir
                    DetectScript       = $script:notepadDetectScript
                    Description        = ($script:notepadDescriptionTemplate -f $script:notepadAppVersion, (Get-Date -Format 'yyyy-MM-dd'))
                }
                if (-not [string]::IsNullOrWhiteSpace($script:notepadInstallCmd))
                {
                    $createAppParams.InstallCmd = $script:notepadInstallCmd
                }
                if (-not [string]::IsNullOrWhiteSpace($script:notepadUninstallCmd))
                {
                    $createAppParams.UninstallCmd = $script:notepadUninstallCmd
                }
                Invoke-PSADTApplicationWithDeploymentTypeSafe -Parameters $createAppParams -LogPrefix 'Notepad++'

                # ----------------------------------------------------------------
                # Step 6 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[Notepad++] Step 6: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:notepadAppName -LogPrefix 'Notepad++'

                # ----------------------------------------------------------------
                # Step 6b - Deploy application to collection
                # ----------------------------------------------------------------
                Get-ChildItem -Path "$env:SystemRoot\Logs\Software" -Filter '*Notepad++*_Install.log' -File -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                Write-Verbose "[Notepad++] Step 6b: Deploying application to collection '$($script:targetCollection)'..."
                $notepadInstallDeploymentCreated = $false
                New-PSADTRequiredDeployment -AppName $script:notepadAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'Notepad++'
                $notepadInstallDeploymentCreated = $true

                # ----------------------------------------------------------------
                # Step 7 - Wait for the expected PSADT install failure log, not final SCCM success
                # ----------------------------------------------------------------
                try
                {
                    Write-Information '[Notepad++] Step 7: Waiting for expected install failure log...' -InformationAction Continue
                    $failureLogValidation = Wait-PSADTInstallFailureLog -App $script:notepadLogValidationApp -DeploymentType 'Install'
                    $failureLogValidation.Success | Should -BeTrue -Because "[Notepad++] PSADT install failure log validation: $($failureLogValidation.Message)"

                    $versionValidation = Test-PsadtAppFileVersion -App $script:notepadVersionValidationApp -ExpectedState 'Deferral'
                    $versionValidation.Success | Should -BeTrue -Because "[Notepad++] expected failed/deferred install to retain old Notepad++ version: $($versionValidation.Message)"
                }
                finally
                {
                    if ($notepadInstallDeploymentCreated)
                    {
                        Remove-CMApplicationDeployment -Name $script:notepadAppName -CollectionName $script:targetCollection -Force -ErrorAction SilentlyContinue
                        Write-Information '::info::[Notepad++] Removed install deployment after expected install failure validation to avoid SCCM retry upgrading the app.' -InformationAction Continue
                    }
                }
            }
        }
    }
}

Describe '7-Zip ForceClose SCCM Deployment' -Tag '7-Zip' {
    Context 'Build 7-Zip ForceClose package from V4 template and deploy into SCCM' {

        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = '7-Zip ForceClose Package Preparation and SCCM Deployment / Build 7-Zip ForceClose package from V4 template and deploy into SCCM'
            $script:CurrentTestMethod = $testInfo.Name
            $script:CurrentTestKey = New-TFTestCaseKey -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod -TestKey $script:CurrentTestKey
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest -TestKey $script:CurrentTestKey
        }

        It '[MCM:SevenZipForceClose_Install] [v4] 7-Zip ForceClose should installed' {
            $sevenZipParameters = Get-SharedPSADTAppParameters -Name '7-Zip ForceClose'
            $ctx = New-PSADTAppTestContextSafe -Parameters $sevenZipParameters -LogPrefix '7-Zip ForceClose'

            $script:v4Dir = $ctx.V4Dir
            $script:sevenZipPackageDir = $ctx.PackageDir
            $script:sevenZipAppName = $ctx.AppName
            $script:sevenZipAppVendor = $ctx.AppVendor
            $script:sevenZipAppVersion = $ctx.AppVersion
            $script:sevenZipDTName = $ctx.DeploymentTypeName
            $script:sevenZipContentUNC = $ctx.ContentUNC
            $script:targetCollection = $ctx.TargetCollection
            $script:siteCode = $ctx.SiteCode
            $script:siteServer = $ctx.SiteServer
            $script:cmModulePath = $ctx.CmModulePath
            $script:sevenZipDetectScript = $sevenZipParameters.DetectScript
            $script:sevenZipDescriptionTemplate = $sevenZipParameters.DescriptionTemplate
            $script:sevenZipInstallCmd = $sevenZipParameters.InstallCmd
            $script:sevenZipUninstallCmd = $sevenZipParameters.UninstallCmd
            $script:sevenZipLogValidationApp = New-PSADTLogValidationAppConfig -TemplateVersion 'V4' -AppFolderName $sevenZipParameters.AppFolderName -Name '7-Zip ForceClose'

            Write-Information '::info::[7-Zip ForceClose] Step 0: Verifying template validation gate...'
            if (-not (Test-PSADTTemplateValidationGate))
            {
                Set-ItResult -Skipped -Because 'Template validation gate not satisfied. Run Validation first or set PSADT_TEMPLATE_VALIDATION_PASSED=true.'
                return
            }
            Write-Information '::info::[7-Zip ForceClose] Template validation gate satisfied.' -InformationAction Continue

            $sevenZipEnvironment = Initialize-SevenZipForceCloseSccmEnvironment -LaunchProcess -LogPrefix '7-Zip ForceClose'
            if (-not $sevenZipEnvironment)
            {
                Set-ItResult -Skipped -Because '7-Zip ForceClose environment not ready. Check logs for details.'
                return
            }

            $templateExpectedInstallerPath = Join-Path 'C:\Tools\Intune' (Split-Path -Path $sevenZipEnvironment.TargetInstallerPath -Leaf)
            New-Item -Path (Split-Path -Path $templateExpectedInstallerPath -Parent) -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $sevenZipEnvironment.TargetInstallerPath -Destination $templateExpectedInstallerPath -Force

            if (-not (Test-PSADTPackageBuildPrerequisites `
                        -TemplateDir $script:v4Dir `
                        -TemplateEnvName 'PSADT_TEMPLATE_V4_DIR' `
                        -SiteCode $script:siteCode `
                        -SiteServer $script:siteServer `
                        -SourceScriptLabel '7-Zip ForceClose\Invoke-AppDeployToolkit.ps1' `
                        -LogPrefix '7-Zip ForceClose' `
                        -UseInformationLogs))
            {
                return
            }

            Initialize-PSADTPackageDirectoryFromTemplateV4 -TemplateDir $script:v4Dir -PackageDir $script:sevenZipPackageDir -LogPrefix '7-Zip ForceClose' -UseInformationLogs

            if (-not (Assert-PSADTContentPathReady `
                        -CmModulePath $script:cmModulePath `
                        -PackageDir $script:sevenZipPackageDir `
                        -ContentUNC $script:sevenZipContentUNC `
                        -LogPrefix '7-Zip ForceClose' `
                        -UseInformationLogs))
            {
                return
            }

            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                $createAppParams = @{
                    AppName            = $script:sevenZipAppName
                    Vendor             = $script:sevenZipAppVendor
                    Version            = $script:sevenZipAppVersion
                    DeploymentTypeName = $script:sevenZipDTName
                    ContentUNC         = $script:sevenZipContentUNC
                    PackageDir         = $script:sevenZipPackageDir
                    DetectScript       = $script:sevenZipDetectScript
                    Description        = ($script:sevenZipDescriptionTemplate -f $script:sevenZipAppVersion, (Get-Date -Format 'yyyy-MM-dd'))
                }
                if (-not [string]::IsNullOrWhiteSpace($script:sevenZipInstallCmd))
                {
                    $createAppParams.InstallCmd = $script:sevenZipInstallCmd
                }
                if (-not [string]::IsNullOrWhiteSpace($script:sevenZipUninstallCmd))
                {
                    $createAppParams.UninstallCmd = $script:sevenZipUninstallCmd
                }
                Invoke-PSADTApplicationWithDeploymentTypeSafe -Parameters $createAppParams -LogPrefix '7-Zip ForceClose'

                Start-PSADTContentDistributionAndAssert -AppName $script:sevenZipAppName -LogPrefix '7-Zip ForceClose'
                New-PSADTRequiredDeployment -AppName $script:sevenZipAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix '7-Zip ForceClose'

                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:sevenZipAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                Assert-PSADTDeploymentLogValidation -App $script:sevenZipLogValidationApp -DeploymentType 'Install' -LogPrefix '7-Zip ForceClose'
                $script:sevenZipInstallDeploySucceeded = $true
            }
        }

        It '[MCM:SevenZipForceClose_Uninstall] [v4] 7-Zip ForceClose should uninstall with ForceCloseProcessesCountdown' {
            if (-not $script:sevenZipInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test '7-Zip ForceClose should installed' did not complete successfully"
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

            $sevenZipFileManager = Join-Path ${env:ProgramFiles} '7-Zip\7zFM.exe'
            Start-PSADTTestAppProcess -FilePath $sevenZipFileManager -ProcessName '7zFM' -Description 'installed 7zFM' -LogPrefix '7-Zip ForceClose'

            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                $app = Get-CMApplication -Name $script:sevenZipAppName -ErrorAction SilentlyContinue
                $app | Should -Not -BeNullOrEmpty -Because '7-Zip ForceClose application must exist before creating uninstall deployment'

                New-PSADTRequiredDeployment -AppName $script:sevenZipAppName -TargetCollection $script:targetCollection -DeployAction Uninstall -LogPrefix '7-Zip ForceClose'

                Write-Information '[7-Zip ForceClose] Polling uninstall deployment status...' -InformationAction Continue
                [void](Assert-PSADTDeploymentSummarySuccess -AppName $script:sevenZipAppName -SiteCode $script:siteCode -Label 'Uninstall deployment')
                Assert-PSADTDeploymentLogValidation -App $script:sevenZipLogValidationApp -DeploymentType 'Uninstall' -LogPrefix '7-Zip ForceClose'

                $forceCloseLogValidation = Test-PsadtForceCloseCountdownLog -App $script:sevenZipLogValidationApp -DeploymentType 'Uninstall'
                $forceCloseLogValidation.Success | Should -BeTrue -Because "[7-Zip ForceClose] PSADT ForceCloseProcessesCountdown validation: $($forceCloseLogValidation.Message)"
            }
        }
    }
}

Describe 'DigiExam SCCM Deployment using V3 template and MSI installer' -Tag 'DigiExam' {
    Context 'Build DigiExam package from V3 template and deploy into SCCM' {

        BeforeAll {
            $digiExamParameters = Get-SharedPSADTAppParameters -Name 'Digiexam'
            $ctx = New-PSADTAppTestContextSafe -Parameters $digiExamParameters -LogPrefix 'DigiExam'

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
            $script:digiExamDetectScript = $digiExamParameters.DetectScript
            $script:digiExamDescriptionTemplate = $digiExamParameters.DescriptionTemplate
            $script:digiExamInstallCmd = $digiExamParameters.InstallCmd
            $script:digiExamUninstallCmd = $digiExamParameters.UninstallCmd
            $script:digiExamLogValidationApp = New-PSADTLogValidationAppConfig -TemplateVersion 'V3' -AppFolderName 'Digiexam' -Name 'DigiExam'
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

        It '[MCM:Digiexam_Install] [v3] DigiExam should installed' {
            Write-Information "::info::[DigiExam] Step 0: Verifying template validation gate..."
            Write-Information "DigiExam SourceScript: $script:digiExamSourceScript"
            Write-Information "DigiExam PackageDir: $script:digiExamPackageDir"
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
                        -SourceScriptLabel 'Digiexam\Deploy-Application.ps1' `
                        -LogPrefix 'DigiExam' `
                        -UseInformationLogs))
            {
                return
            }
            Write-Information "::info::[DigiExam] Prerequisites verified." -InformationAction Continue

            # ----------------------------------------------------------------
            # Step 2 - Copy V3 template to DigiExam package directory
            # ----------------------------------------------------------------
            Initialize-PSADTPackageDirectoryFromTemplate -TemplateDir $script:v3Dir -PackageDir $script:digiExamPackageDir -LogPrefix 'DigiExam' -UseInformationLogs
            Write-Information "::info::[DigiExam] V3 template copied to DigiExam package directory." -InformationAction Continue

            # ----------------------------------------------------------------
            # Step 3 - Replace Invoke-AppDeployToolkit.ps1 with DigiExam version
            # ----------------------------------------------------------------
            $destScript = Update-PSADTPackageDeployScript `
                -PackageDir $script:digiExamPackageDir `
                -SourceScript $script:digiExamSourceScript `
                -ExpectedContentPattern 'DigiExam' `
                -LogPrefix 'DigiExam' `
                -UseInformationLogs
            Write-Information "::info::[DigiExam] Invoke-AppDeployToolkit.ps1 replaced with DigiExam version." -InformationAction Continue

            # ----------------------------------------------------------------
            # Step 4 - Copy DigiExam MSI into Files folder
            # ----------------------------------------------------------------
            $msiSource = 'C:\Tools\Intune\Digiexam_26.1.24_x64_en-US.msi'
            Copy-PSADTPackageInstallerToFiles `
                -DeployScriptPath $destScript.FullName `
                -InstallerSource $msiSource `
                -InstallerLabel 'MSI' `
                -LogPrefix 'DigiExam' `
                -UseInformationLogs `
                -ExpectedFileName 'Digiexam_26.1.24_x64_en-US.msi'
            Write-Information "::info::[DigiExam] DigiExam MSI copied to Files folder." -InformationAction Continue

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
            Write-Information "::info::[DigiExam] SMB content share and directories exist." -InformationAction Continue
            # ----------------------------------------------------------------
            # Step 6 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[DigiExam] Step 6: Importing DigiExam application into SCCM...'
            Invoke-PSADTInCMSiteContext -SiteCode $script:siteCode -SiteServer $script:siteServer -CmModulePath $script:cmModulePath -ScriptBlock {
                Write-Information '::info::[DigiExam] SCCM module imported and CMSite location set. Running SCCM operations...' -InformationAction Continue
                $createAppParams = @{
                    AppName            = $script:digiExamAppName
                    Vendor             = $script:digiExamAppVendor
                    Version            = $script:digiExamAppVersion
                    DeploymentTypeName = $script:digiExamDTName
                    ContentUNC         = $script:digiExamContentUNC
                    PackageDir         = $script:digiExamPackageDir
                    DetectScript       = $script:digiExamDetectScript
                    Description        = ($script:digiExamDescriptionTemplate -f $script:digiExamAppVersion, (Get-Date -Format 'yyyy-MM-dd'))
                }
                if (-not [string]::IsNullOrWhiteSpace($script:digiExamInstallCmd))
                {
                    $createAppParams.InstallCmd = $script:digiExamInstallCmd
                }
                if (-not [string]::IsNullOrWhiteSpace($script:digiExamUninstallCmd))
                {
                    $createAppParams.UninstallCmd = $script:digiExamUninstallCmd
                }
                Invoke-PSADTApplicationWithDeploymentTypeSafe -Parameters $createAppParams -LogPrefix 'DigiExam'
                Write-Information "::info::[DigiExam] DigiExam application imported into SCCM." -InformationAction Continue
                # ----------------------------------------------------------------
                # Step 7 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[DigiExam] Step 7: Triggering content distribution...'
                Start-PSADTContentDistributionAndAssert -AppName $script:digiExamAppName -LogPrefix 'DigiExam'
                Write-Information "::info::[DigiExam] Content distribution triggered." -InformationAction Continue
                # ----------------------------------------------------------------
                # Step 7b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[DigiExam] Step 7b: Deploying application to collection '$($script:targetCollection)'..."
                New-PSADTRequiredDeployment -AppName $script:digiExamAppName -TargetCollection $script:targetCollection -DeployAction Install -LogPrefix 'DigiExam'
                Write-Information "::info::[DigiExam] DigiExam application deployed to collection '$($script:targetCollection)'." -InformationAction Continue
                # ----------------------------------------------------------------
                # Step 8 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[DigiExam] Step 8: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Assert-PSADTDeploymentSummarySuccess -AppName $script:digiExamAppName -SiteCode $script:siteCode -Label 'Deployment'
                Write-Information $deploymentSummary -InformationAction Continue
                Assert-PSADTDeploymentLogValidation -App $script:digiExamLogValidationApp -DeploymentType 'Install' -LogPrefix 'DigiExam'
                $script:digiExamInstallDeploySucceeded = $true
            }
        }

        It '[MCM:Digiexam_Uninstall] [v3] DigiExam should uninstalled' {
            if (-not $script:digiExamInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'DigiExam should installed' did not complete successfully"
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
                Assert-PSADTDeploymentLogValidation -App $script:digiExamLogValidationApp -DeploymentType 'Uninstall' -LogPrefix 'DigiExam'
            }
        }
    }
}

Describe 'Everything SCCM Deployment using V3 template and EXE installer' -Tag 'Everything' {
    Context 'Build Everything package from V3 template and deploy into SCCM' {

        BeforeAll {
            $everythingParameters = Get-SharedPSADTAppParameters -Name 'Everything'
            $ctx = New-PSADTAppTestContextSafe -Parameters $everythingParameters -LogPrefix 'Everything'

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
            $script:everythingDetectScript = $everythingParameters.DetectScript
            $script:everythingDescriptionTemplate = $everythingParameters.DescriptionTemplate
            $script:everythingInstallCmd = $everythingParameters.InstallCmd
            $script:everythingUninstallCmd = $everythingParameters.UninstallCmd
            $script:everythingLogValidationApp = New-PSADTLogValidationAppConfig -TemplateVersion 'V3' -AppFolderName 'Everything' -Name 'Everything'
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

        It '[MCM:Everything_Install] [v3] Everything should installed' {
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
                $createAppParams = @{
                    AppName            = $script:everythingAppName
                    Vendor             = $script:everythingAppVendor
                    Version            = $script:everythingAppVersion
                    DeploymentTypeName = $script:everythingDTName
                    ContentUNC         = $script:everythingContentUNC
                    PackageDir         = $script:everythingPackageDir
                    DetectScript       = $script:everythingDetectScript
                    Description        = ($script:everythingDescriptionTemplate -f $script:everythingAppVersion, (Get-Date -Format 'yyyy-MM-dd'))
                }
                if (-not [string]::IsNullOrWhiteSpace($script:everythingInstallCmd))
                {
                    $createAppParams.InstallCmd = $script:everythingInstallCmd
                }
                if (-not [string]::IsNullOrWhiteSpace($script:everythingUninstallCmd))
                {
                    $createAppParams.UninstallCmd = $script:everythingUninstallCmd
                }
                Invoke-PSADTApplicationWithDeploymentTypeSafe -Parameters $createAppParams -LogPrefix 'Everything'

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
                Assert-PSADTDeploymentLogValidation -App $script:everythingLogValidationApp -DeploymentType 'Install' -LogPrefix 'Everything'
                $script:everythingInstallDeploySucceeded = $true
            }
        }

        It '[MCM:Everything_Uninstall] [v3] Everything should uninstalled' {
            if (-not $script:everythingInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'Everything should installed' did not complete successfully"
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
                Assert-PSADTDeploymentLogValidation -App $script:everythingLogValidationApp -DeploymentType 'Uninstall' -LogPrefix 'Everything'
            }
        }
    }
}
