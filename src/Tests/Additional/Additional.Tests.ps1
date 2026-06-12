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

    function script:Invoke-WinSCPSccmClientEvaluation
    {
        Write-Information "Triggering policy/application/update evaluation" -InformationAction Continue

        # Computer policy
        $trigger = "{00000000-0000-0000-0000-000000000021}"
        [void]([wmiclass]"\\.\root\ccm:SMS_Client").TriggerSchedule($trigger)

        # Application evaluation
        $trigger = "{00000000-0000-0000-0000-000000000121}"
        [void]([wmiclass]"\\.\root\ccm:SMS_Client").TriggerSchedule($trigger)

        # Send unsent state message (report deployment state back to site)
        $trigger = "{00000000-0000-0000-0000-000000000111}"
        [void]([wmiclass]"\\.\root\ccm:SMS_Client").TriggerSchedule($trigger)
    }

    function script:Invoke-WinSCPPollDeploymentStatus
    {
        <#
            Polls SMS_DeploymentSummary until at least one device reports success
            or the timeout is reached.
            Returns the final SMS_DeploymentSummary CIM instance (or $null).
        #>
        param (
            [string]$AppName,
            [string]$SiteCode,
            [string]$Label = 'Deployment',
            [int]$MaxWaitSeconds = 3600,
            [int]$PollInterval = 180
        )

        $elapsed = 0
        $summary = $null
        $cimNamespace = "root\SMS\Site_$SiteCode"

        do
        {
            $deployments = Get-CMDeployment -SoftwareName $AppName -ErrorAction SilentlyContinue
            $deployments | ForEach-Object { Invoke-CMDeploymentSummarization -DeploymentId $_.DeploymentId | Out-Null }

            $summary = $null
            if (-not [string]::IsNullOrWhiteSpace($SiteCode))
            {
                $summary = Get-CimInstance -Namespace $cimNamespace -ClassName SMS_DeploymentSummary -ErrorAction SilentlyContinue | Where-Object { $_.ApplicationName -eq $AppName } | Select-Object -First 1
            }

            if ($summary)
            {
                Write-Information "[$AppName] $Label status (elapsed ${elapsed}s): Success=$($summary.NumberSuccess) InProgress=$($summary.NumberInProgress) Error=$($summary.NumberErrors) Targeted=$($summary.NumberTargeted)" -InformationAction Continue
                if ($summary.NumberSuccess -gt 0)
                {
                    break
                }
            }

            if ($elapsed -lt $MaxWaitSeconds)
            {
                Write-Information "[$AppName] $Label not yet successful - waiting ${PollInterval}s before next check..." -InformationAction Continue
                Invoke-WinSCPSccmClientEvaluation | Out-Null
                Start-Sleep -Seconds $PollInterval
                $elapsed += $PollInterval
            }
            else
            {
                break
            }
        }
        while ($elapsed -le $MaxWaitSeconds)

        # Final authoritative read - only if the loop did not already capture a result
        if (-not $summary -and -not [string]::IsNullOrWhiteSpace($SiteCode))
        {
            $summary = Get-CimInstance -Namespace $cimNamespace -ClassName SMS_DeploymentSummary -ErrorAction SilentlyContinue | Where-Object { $_.ApplicationName -eq $AppName } | Select-Object -First 1
        }
        return $summary
    }

    function script:Test-PSADTTemplateValidationGate
    {
        <#
            Allows SCCM package tests to run only after template validation.
            Gate can be satisfied by:
            1) Current test run has already passed validation, or
            2) Pipeline sets PSADT_TEMPLATE_VALIDATION_PASSED=true
        #>
        if ($script:TemplateValidationPassed)
        {
            return $true
        }

        $gateFromEnv = $env:PSADT_TEMPLATE_VALIDATION_PASSED
        return @('1', 'true', 'yes', 'passed') -contains "$gateFromEnv".ToLowerInvariant()
    }

    function script:Remove-DirectoryWithRetry
    {
        <#
            Removes a directory tree with retry to handle transient file locks in CI.
            Falls back to cmd rmdir for stubborn cases where Remove-Item can fail on Windows.
        #>
        param (
            [Parameter(Mandatory = $true)]
            [string]$Path,
            [int]$MaxAttempts = 4,
            [int]$DelaySeconds = 2
        )

        if (-not (Test-Path -LiteralPath $Path))
        {
            return
        }

        $lastError = $null
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++)
        {
            try
            {
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $Path))
                {
                    return
                }
            }
            catch
            {
                $lastError = $_
            }

            # Fallback for stubborn directory trees on Windows CI agents.
            try
            {
                cmd.exe /c "rmdir /s /q \"$Path\"" | Out-Null
                if (-not (Test-Path -LiteralPath $Path))
                {
                    return
                }
            }
            catch
            {
                $lastError = $_
            }

            if ($attempt -lt $MaxAttempts)
            {
                Start-Sleep -Seconds $DelaySeconds
            }
        }

        $msg = if ($lastError) { $lastError.Exception.Message } else { 'Unknown error while removing directory.' }
        throw "Failed to remove directory '$Path' after $MaxAttempts attempts. Last error: $msg"
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
            Write-Verbose "[BeforeEach] TestClass: $($script:CurrentTestClass)"
            Write-Verbose "[BeforeEach] TestMethod: $($script:CurrentTestMethod)"
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest
        }

        It 'Template environment variables, directories, and contents are valid' {
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

Describe 'winSCP Package Preparation and SCCM Deployment' -Tag 'WinSCP' {
    Context 'Build winSCP package from V4 template and deploy into SCCM' {

        BeforeAll {
            $script:v4Dir = $env:PSADT_TEMPLATE_V4_DIR
            $script:winscpSourceScript = Join-Path $PSScriptRoot 'winSCP\Invoke-AppDeployToolkit.ps1'
            $script:winscpPackageDir = 'C:\PSADT\winSCP'
            $script:winscpAppName = 'WinSCP (PSADT v4 winSCP)'
            $script:winscpAppVendor = 'Martin Prikryl'
            $script:winscpAppVersion = '6.5.6'
            $script:winscpDTName = "WinSCP $script:winscpAppVersion (v4 winSCP)"
            $script:winscpContentUNC = "\\$env:COMPUTERNAME\PSADT_Content`$\winSCP"
            $script:targetCollection = if ($env:SCCM_TARGET_COLLECTION) { $env:SCCM_TARGET_COLLECTION } else { 'All Systems' }
            $script:winscpInstallDeploySucceeded = $false

            $script:siteCode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Operations Management' -Name 'Site Code' -ErrorAction SilentlyContinue).'Site Code'
            $script:siteServer = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Provider Location' -ErrorAction SilentlyContinue).'Provider Location'

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
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest
        }

        It 'Builds winSCP package and deploys into SCCM' {
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
            if (-not $script:v4Dir)
            {
                Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V4_DIR not set'
                return
            }
            if ([string]::IsNullOrWhiteSpace($script:siteCode) -or [string]::IsNullOrWhiteSpace($script:siteServer))
            {
                Set-ItResult -Skipped -Because 'SCCM siteCode or siteServer not configured (not an SCCM-managed environment)'
                return
            }
            Write-Information "::info::[winSCP] Step 1: Verifying prerequisites..."
            Test-Path $script:v4Dir | Should -BeTrue -Because "V4 template directory '$script:v4Dir' must exist"
            Write-Information "::info::[winSCP] V4 template directory '$script:v4Dir' verified." -InformationAction Continue
            Test-Path $script:winscpSourceScript | Should -BeTrue -Because "winSCP\Invoke-AppDeployToolkit.ps1 must exist"
            Write-Information "::info::[winSCP] winSCP\Invoke-AppDeployToolkit.ps1 verified." -InformationAction Continue

            # ----------------------------------------------------------------
            # Step 2 - Copy V4 template to winSCP package directory
            # ----------------------------------------------------------------
            Write-Information "::info::[winSCP] Step 2: Copying V4 template to winSCP package directory..."
            if (Test-Path $script:winscpPackageDir)
            {
                Write-Information "::warning::[winSCP] Package directory '$script:winscpPackageDir' already exists, removing it." -InformationAction Continue
                Remove-DirectoryWithRetry -Path $script:winscpPackageDir
                Write-Information "::info::[winSCP] Package directory '$script:winscpPackageDir' removed." -InformationAction Continue
            }
            New-Item -Path $script:winscpPackageDir -ItemType Directory -Force | Out-Null
            Write-Information "::info::[winSCP] Package directory '$script:winscpPackageDir' created." -InformationAction Continue
            # Copy template contents (not the template folder) to avoid creating an extra nested directory.
            Copy-Item -Path "$script:v4Dir\*" -Destination $script:winscpPackageDir -Recurse -Force
            Test-Path $script:winscpPackageDir | Should -BeTrue

            # ----------------------------------------------------------------
            # Step 3 - Replace Invoke-AppDeployToolkit.ps1 with winSCP version
            # ----------------------------------------------------------------
            Write-Information "::info::[winSCP] Step 3: Replacing Invoke-AppDeployToolkit.ps1 with winSCP version..."
            $allDestScripts = Get-ChildItem -Path $script:winscpPackageDir -Filter 'Invoke-AppDeployToolkit.ps1' -Recurse -File -ErrorAction SilentlyContinue
            $destScript = $allDestScripts | Select-Object -First 1
            $destScript | Should -Not -BeNullOrEmpty -Because 'Invoke-AppDeployToolkit.ps1 must exist in the copied V4 template'
            Copy-Item -Path $script:winscpSourceScript -Destination $destScript.FullName -Force
            $content = Get-Content -Path $destScript.FullName -Raw
            $content | Should -Match 'WinSCP'

            # ----------------------------------------------------------------
            # Step 4 - Copy WinSCP MSI into Files folder
            # ----------------------------------------------------------------
            Write-Information "::info::[winSCP] Step 4: Copying WinSCP MSI into Files folder..."
            $msiSource = 'C:\Tools\Intune\WinSCP\WinSCP-6.5.6.msi'
            if (-not (Test-Path $msiSource))
            {
                Write-Information "::warning::[winSCP] MSI not found at '$msiSource', skipping MSI copy step." -InformationAction Continue
            }
            else
            {
                # Derive Files directory from discovered script location to handle v4 subdirectory structure
                $scriptDir = Split-Path -Path $destScript.FullName -Parent
                $filesDir = Join-Path -Path $scriptDir -ChildPath 'Files'
                if (-not (Test-Path $filesDir))
                {
                    New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
                }
                Copy-Item -Path $msiSource -Destination $filesDir -Force
                Test-Path (Join-Path $filesDir 'WinSCP-6.5.6.msi') | Should -BeTrue
            }

            # ----------------------------------------------------------------
            # Step 5 - Verify SMB content share and directories exist
            # ----------------------------------------------------------------
            Write-Information "::info::[winSCP] Step 5: Verifying SMB content share and package directories..."
            if (-not $script:cmModulePath)
            {
                Set-ItResult -Skipped -Because 'ConfigurationManager module not available - skipping SCCM steps'
                return
            }
            # SMB share should already be created by workflow; ensure package directory exists
            if (-not (Test-Path $script:winscpPackageDir))
            {
                New-Item -ItemType Directory -Path $script:winscpPackageDir -Force | Out-Null
                Write-Information "::info::[winSCP] Created package directory: $($script:winscpPackageDir)" -InformationAction Continue
            }
            Test-Path $script:winscpContentUNC | Should -BeTrue -Because "SMB content UNC path '$($script:winscpContentUNC)' must exist"

            # ----------------------------------------------------------------
            # Step 6 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[winSCP] Step 6: Importing winSCP application into SCCM...'
            if ([string]::IsNullOrWhiteSpace($script:siteCode))
            {
                throw "siteCode cannot be null or empty"
            }
            if ([string]::IsNullOrWhiteSpace($script:siteServer))
            {
                throw "siteServer cannot be null or empty"
            }
            Import-Module $script:cmModulePath -ErrorAction Stop
            $script:WinSCPSiteOriginalLocation = Get-Location
            if (-not (Get-PSDrive -Name $script:siteCode -ErrorAction SilentlyContinue))
            {
                New-PSDrive -Name $script:siteCode -PSProvider CMSite -Root $script:siteServer | Out-Null
            }
            Set-Location "$($script:siteCode):\"
            try
            {
                # Remove existing application
                if (Get-CMApplication -Name $script:winscpAppName -ErrorAction SilentlyContinue)
                {
                    $existingDeps = Get-CMApplicationDeployment -Name $script:winscpAppName -ErrorAction SilentlyContinue
                    foreach ($dep in $existingDeps)
                    {
                        Remove-CMApplicationDeployment -Name $script:winscpAppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
                    }
                    Remove-CMApplication -Name $script:winscpAppName -Force
                    Start-Sleep -Seconds 2
                }

                New-CMApplication `
                    -Name            $script:winscpAppName `
                    -Publisher       $script:winscpAppVendor `
                    -SoftwareVersion $script:winscpAppVersion `
                    -LocalizedName   $script:winscpAppName `
                    -Description     "PSADT v4 winSCP template - WinSCP $script:winscpAppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')" | Out-Null

                $installCmd = if (Test-Path (Join-Path $script:winscpPackageDir 'Invoke-AppDeployToolkit.exe'))
                {
                    'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive'
                }
                else
                {
                    'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install'
                }
                $uninstallCmd = if (Test-Path (Join-Path $script:winscpPackageDir 'Invoke-AppDeployToolkit.exe'))
                {
                    'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Interactive'
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
if ($app) { Write-Host "Installed" }
'@

                Add-CMScriptDeploymentType `
                    -ApplicationName           $script:winscpAppName `
                    -DeploymentTypeName        $script:winscpDTName `
                    -ContentLocation           $script:winscpContentUNC `
                    -InstallCommand            $installCmd `
                    -UninstallCommand          $uninstallCmd `
                    -ScriptLanguage            PowerShell `
                    -ScriptText                $detectScript `
                    -InstallationBehaviorType  InstallForSystem `
                    -LogonRequirementType      WhetherOrNotUserLoggedOn `
                    -RebootBehavior            BasedOnExitCode `
                    -SlowNetworkDeploymentMode Download `
                    -RequireUserInteraction `
                    -MaximumRuntimeMins        30 `
                    -EstimatedRuntimeMins      5 | Out-Null

                $dt = Get-CMDeploymentType -ApplicationName $script:winscpAppName -DeploymentTypeName $script:winscpDTName
                Add-CMDeploymentTypeReturnCode -InputObject $dt -ReturnCode 3010 -CodeType SoftReboot -Name 'Reboot Required' | Out-Null
                Add-CMDeploymentTypeReturnCode -InputObject $dt -ReturnCode 1641 -CodeType HardReboot -Name 'Reboot Initiated' | Out-Null

                $created = Get-CMApplication -Name $script:winscpAppName -ErrorAction SilentlyContinue
                $created | Should -Not -BeNullOrEmpty

                # ----------------------------------------------------------------
                # Step 7 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[winSCP] Step 7: Triggering content distribution...'
                $dpGroups = Get-CMDistributionPointGroup -ErrorAction SilentlyContinue
                $dpList = Get-CMDistributionPoint -ErrorAction SilentlyContinue

                if ($dpGroups)
                {
                    foreach ($grp in $dpGroups)
                    {
                        Start-CMContentDistribution -ApplicationName $script:winscpAppName `
                            -DistributionPointGroupName $grp.Name -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                elseif ($dpList)
                {
                    foreach ($dp in $dpList)
                    {
                        Start-CMContentDistribution -ApplicationName $script:winscpAppName `
                            -DistributionPointName $dp.NetworkOSPath.TrimStart('\') -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                else
                {
                    Write-Information '::warning::[winSCP] No distribution points or DP groups found - content distribution skipped.' -InformationAction Continue
                }
                # Check content distribution status via Get-CMDistributionStatus
                # Poll every 60 seconds for up to 10 minutes until all DPs report success
                $packageId = (Get-CMApplication -Name $script:winscpAppName -ErrorAction SilentlyContinue).PackageID
                if ($packageId)
                {
                    $maxWaitSeconds = 600
                    $pollIntervalSeconds = 60
                    $elapsed = 0
                    $distributionStatus = $null

                    do
                    {
                        $distributionStatus = Get-CMDistributionStatus -Id $packageId -ErrorAction SilentlyContinue
                        if ($distributionStatus)
                        {
                            Write-Verbose "[winSCP] Distribution status (elapsed ${elapsed}s): Targeted=$($distributionStatus.Targeted) Success=$($distributionStatus.NumberSuccess) InProgress=$($distributionStatus.NumberInProgress) Errors=$($distributionStatus.NumberErrors)"
                            if ($distributionStatus.NumberSuccess -ge $distributionStatus.Targeted -and $distributionStatus.Targeted -gt 0)
                            {
                                break
                            }
                        }

                        if ($elapsed -lt $maxWaitSeconds)
                        {
                            Write-Verbose "[winSCP] Distribution not yet complete - waiting ${pollIntervalSeconds}s before next check..."
                            Start-Sleep -Seconds $pollIntervalSeconds
                            $elapsed += $pollIntervalSeconds
                        }
                        else
                        {
                            break
                        }
                    }
                    while ($elapsed -le $maxWaitSeconds)

                    $distributionStatus | Should -Not -BeNullOrEmpty -Because 'Content distribution status must exist'
                    $distributionStatus.NumberSuccess | Should -Be $distributionStatus.Targeted -Because "All $($distributionStatus.Targeted) targeted distribution points must have received the content successfully (waited up to ${maxWaitSeconds}s)"
                }
                else
                {
                    Write-Information '::warning::[winSCP] Could not retrieve PackageID for distribution status check.' -InformationAction Continue
                }

                # ----------------------------------------------------------------
                # Step 7b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[winSCP] Step 7b: Deploying application to collection '$($script:targetCollection)'..."

                # Validate collection exists if not using default
                if ($script:targetCollection -ne 'All Systems')
                {
                    $col = Get-CMDeviceCollection -Name $script:targetCollection -ErrorAction SilentlyContinue
                    $col | Should -Not -BeNullOrEmpty -Because "Collection '$($script:targetCollection)' must exist in SCCM"
                    Write-Verbose "[winSCP] Collection validated: $($script:targetCollection) ($($col.MemberCount) device(s))"
                }

                # Remove existing deployment before recreating
                $existDeploy = Get-CMApplicationDeployment -Name $script:winscpAppName -CollectionName $script:targetCollection -ErrorAction SilentlyContinue
                if ($existDeploy)
                {
                    Remove-CMApplicationDeployment -Name $script:winscpAppName -CollectionName $script:targetCollection -Force -ErrorAction SilentlyContinue
                    Write-Verbose "[winSCP] Removed existing deployment: $($script:winscpAppName) -> $($script:targetCollection)"
                }

                New-CMApplicationDeployment `
                    -Name                       $script:winscpAppName `
                    -CollectionName             $script:targetCollection `
                    -DeployAction               Install `
                    -DeployPurpose              Required `
                    -UserNotification           DisplaySoftwareCenterOnly `
                    -TimeBaseOn                 LocalTime `
                    -OverrideServiceWindow      $false `
                    -RebootOutsideServiceWindow $false | Out-Null

                $createdDeploy = Get-CMApplicationDeployment -Name $script:winscpAppName -CollectionName $script:targetCollection -ErrorAction SilentlyContinue
                $createdDeploy | Should -Not -BeNullOrEmpty -Because "Deployment of '$($script:winscpAppName)' to '$($script:targetCollection)' must be created successfully"
                Write-Verbose "[winSCP] Deployment created: $($script:winscpAppName) -> $($script:targetCollection) (Required)"

                # ----------------------------------------------------------------
                # Step 8 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[winSCP] Step 8: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Invoke-WinSCPPollDeploymentStatus `
                    -AppName        $script:winscpAppName `
                    -SiteCode       $script:siteCode `
                    -Label          'Deployment' `
                    -MaxWaitSeconds 3600 `
                    -PollInterval   180
                $deploymentSummary | Should -Not -BeNullOrEmpty -Because 'Application deployment status must exist'
                # write $deploymentSummary
                Write-Information $deploymentSummary -InformationAction Continue
                $deploymentSummary.NumberSuccess | Should -BeGreaterThan 0 -Because 'At least one device must have successfully deployed the application (waited up to 3600s)'
                $script:winscpInstallDeploySucceeded = $true
            }
            finally
            {
                if ($script:WinSCPSiteOriginalLocation)
                {
                    Set-Location $script:WinSCPSiteOriginalLocation
                }
            }
        }

        It 'Creates uninstall deployment after winSCP install deployment succeeds' {
            if (-not $script:winscpInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'Builds winSCP package and deploys into SCCM' did not complete successfully"
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

            if ([string]::IsNullOrWhiteSpace($script:siteCode))
            {
                throw "siteCode cannot be null or empty"
            }
            if ([string]::IsNullOrWhiteSpace($script:siteServer))
            {
                throw "siteServer cannot be null or empty"
            }
            Import-Module $script:cmModulePath -ErrorAction Stop
            $script:WinSCPSiteOriginalLocation = Get-Location
            if (-not (Get-PSDrive -Name $script:siteCode -ErrorAction SilentlyContinue))
            {
                New-PSDrive -Name $script:siteCode -PSProvider CMSite -Root $script:siteServer | Out-Null
            }
            Set-Location "$($script:siteCode):\"
            try
            {
                $app = Get-CMApplication -Name $script:winscpAppName -ErrorAction SilentlyContinue
                $app | Should -Not -BeNullOrEmpty -Because 'winSCP application must exist before creating uninstall deployment'

                $existingDeployments = Get-CMApplicationDeployment -Name $script:winscpAppName -CollectionName $script:targetCollection -ErrorAction SilentlyContinue
                foreach ($dep in $existingDeployments)
                {
                    Remove-CMApplicationDeployment -Name $script:winscpAppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
                    Write-Information "Removed existing deployment for '$($script:winscpAppName)' to collection '$($dep.CollectionName)'" -InformationAction Continue
                }
                Start-Sleep -Seconds 2

                New-CMApplicationDeployment `
                    -Name                       $script:winscpAppName `
                    -CollectionName             $script:targetCollection `
                    -DeployAction               Uninstall `
                    -DeployPurpose              Required `
                    -UserNotification           DisplaySoftwareCenterOnly `
                    -TimeBaseOn                 LocalTime `
                    -OverrideServiceWindow      $false `
                    -RebootOutsideServiceWindow $false | Out-Null

                $uninstallDeploy = Get-CMApplicationDeployment -Name $script:winscpAppName -CollectionName $script:targetCollection -ErrorAction SilentlyContinue
                $uninstallDeploy | Should -Not -BeNullOrEmpty -Because "Uninstall deployment of '$($script:winscpAppName)' to '$($script:targetCollection)' must be created successfully"
                Write-Information "[winSCP] Uninstall deployment created: $($script:winscpAppName) -> $($script:targetCollection) (Required)" -InformationAction Continue

                # ----------------------------------------------------------------
                # Step 9 - Poll uninstall deployment status
                # ----------------------------------------------------------------
                Write-Information '[winSCP] Step 9: Polling uninstall deployment status...' -InformationAction Continue
                $uninstallSummary = Invoke-WinSCPPollDeploymentStatus `
                    -AppName        $script:winscpAppName `
                    -SiteCode       $script:siteCode `
                    -Label          'Uninstall deployment' `
                    -MaxWaitSeconds 3600 `
                    -PollInterval   180
                $uninstallSummary | Should -Not -BeNullOrEmpty -Because 'Uninstall deployment status must exist'
                $uninstallSummary.NumberSuccess | Should -BeGreaterThan 0 -Because 'At least one device must have successfully uninstalled the application (waited up to 3600s)'
            }
            finally
            {
                if ($script:WinSCPSiteOriginalLocation)
                {
                    Set-Location $script:WinSCPSiteOriginalLocation
                }
            }
        }
    }
}

Describe 'VLC Package Preparation and SCCM Deployment' -Tag 'VLC' {
    Context 'Build VLC package from V4 template and deploy into SCCM' {

        BeforeAll {
            $script:v4Dir = $env:PSADT_TEMPLATE_V4_DIR
            $script:vlcSourceScript = Join-Path $PSScriptRoot 'VLC\Invoke-AppDeployToolkit.ps1'
            $script:vlcSourceFolder = Join-Path $PSScriptRoot 'VLC'
            $script:vlcPackageDir = 'C:\PSADT\VLC'
            $script:vlcAppName = 'VLC media player (PSADT v4 VLC)'
            $script:vlcAppVendor = 'VideoLAN'
            $script:vlcAppVersion = '3.0.23'
            $script:vlcDTName = "VLC $script:vlcAppVersion (v4 VLC)"
            $script:vlcContentUNC = "\\$env:COMPUTERNAME\PSADT_Content`$\VLC"
            $script:targetCollection = if ($env:SCCM_TARGET_COLLECTION) { $env:SCCM_TARGET_COLLECTION } else { 'All Systems' }
            $script:vlcInstallDeploySucceeded = $false

            $script:siteCode = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Operations Management' -Name 'Site Code' -ErrorAction SilentlyContinue).'Site Code'
            $script:siteServer = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Provider Location' -ErrorAction SilentlyContinue).'Provider Location'

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
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
        }

        AfterEach {
            $currentTest = $____Pester.CurrentTest
            Invoke-TFUpdateTestCase -TestResult $currentTest
        }

        It 'Builds VLC package and deploys into SCCM' {
            if (-not (Test-PSADTTemplateValidationGate))
            {
                Set-ItResult -Skipped -Because 'Template validation gate not satisfied. Run Validation first or set PSADT_TEMPLATE_VALIDATION_PASSED=true.'
                return
            }

            # ----------------------------------------------------------------
            # Step 1 - Verify prerequisites
            # ----------------------------------------------------------------
            if (-not $script:v4Dir)
            {
                Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V4_DIR not set'
                return
            }
            if ([string]::IsNullOrWhiteSpace($script:siteCode) -or [string]::IsNullOrWhiteSpace($script:siteServer))
            {
                Set-ItResult -Skipped -Because 'SCCM siteCode or siteServer not configured (not an SCCM-managed environment)'
                return
            }
            Test-Path $script:v4Dir | Should -BeTrue -Because 'V4 template directory must exist'
            Test-Path $script:vlcSourceScript | Should -BeTrue -Because 'VLC\Invoke-AppDeployToolkit.ps1 must exist'

            # ----------------------------------------------------------------
            # Step 2 - Copy V4 template to VLC package directory
            # ----------------------------------------------------------------
            Write-Verbose '[VLC] Step 2: Copying V4 template to VLC package directory...'
            if (Test-Path $script:vlcPackageDir)
            {
                Remove-Item $script:vlcPackageDir -Recurse -Force
            }
            Copy-Item -Path $script:v4Dir -Destination $script:vlcPackageDir -Recurse -Force
            Test-Path $script:vlcPackageDir | Should -BeTrue

            # ----------------------------------------------------------------
            # Step 3 - Replace Invoke-AppDeployToolkit.ps1 with VLC version
            # ----------------------------------------------------------------
            Write-Verbose '[VLC] Step 3: Replacing Invoke-AppDeployToolkit.ps1 with VLC version...'
            $allDestScripts = Get-ChildItem -Path $script:vlcPackageDir -Filter 'Invoke-AppDeployToolkit.ps1' -Recurse -File -ErrorAction SilentlyContinue
            $destScript = $allDestScripts | Select-Object -First 1
            $destScript | Should -Not -BeNullOrEmpty -Because 'Invoke-AppDeployToolkit.ps1 must exist in the copied V4 template'
            # copy vlc folder contents (not the folder itself) to ensure any additional files (e.g. for detection logic) are included in the package source
            Copy-Item -Path "$script:vlcSourceFolder\*" -Destination $script:vlcPackageDir -Recurse -Force
            $content = Get-Content -Path $destScript.FullName -Raw
            $content | Should -Match 'VLC'

            # ----------------------------------------------------------------
            # Step 4 - Copy VLC installer into Files folder
            # ----------------------------------------------------------------
            Write-Verbose '[VLC] Step 4: Copying VLC installer into Files folder...'
            $installerSource = "C:\Tools\Intune\VLC\vlc-$($script:vlcAppVersion)-win64.exe"
            if (-not (Test-Path $installerSource))
            {
                Write-Information "::warning::[VLC] Installer not found at '$installerSource', skipping installer copy step." -InformationAction Continue
            }
            else
            {
                # Derive Files directory from discovered script location to handle v4 subdirectory structure
                $vlcScriptDir = Split-Path -Path $destScript.FullName -Parent
                $filesDir = Join-Path -Path $vlcScriptDir -ChildPath 'Files'
                if (-not (Test-Path $filesDir))
                {
                    New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
                }
                Copy-Item -Path $installerSource -Destination $filesDir -Force
                Test-Path (Join-Path $filesDir "vlc-$($script:vlcAppVersion)-win64.exe") | Should -BeTrue
            }

            # ----------------------------------------------------------------
            # Step 5 - Verify SMB content share and directories exist
            # ----------------------------------------------------------------
            Write-Verbose '[VLC] Step 5: Verifying SMB content share and package directories...'
            if (-not $script:cmModulePath)
            {
                Set-ItResult -Skipped -Because 'ConfigurationManager module not available - skipping SCCM steps'
                return
            }
            # SMB share should already be created by workflow; ensure package directory exists
            if (-not (Test-Path $script:vlcPackageDir))
            {
                New-Item -ItemType Directory -Path $script:vlcPackageDir -Force | Out-Null
                Write-Verbose "[VLC] Created package directory: $($script:vlcPackageDir)"
            }
            Test-Path $script:vlcContentUNC | Should -BeTrue -Because "SMB content UNC path '$($script:vlcContentUNC)' must exist"

            # ----------------------------------------------------------------
            # Step 6 - Import application into SCCM
            # ----------------------------------------------------------------
            Write-Verbose '[VLC] Step 6: Importing VLC application into SCCM...'
            if ([string]::IsNullOrWhiteSpace($script:siteCode))
            {
                throw "siteCode cannot be null or empty"
            }
            if ([string]::IsNullOrWhiteSpace($script:siteServer))
            {
                throw "siteServer cannot be null or empty"
            }
            Import-Module $script:cmModulePath -ErrorAction Stop
            $script:VLCSiteOriginalLocation = Get-Location
            if (-not (Get-PSDrive -Name $script:siteCode -ErrorAction SilentlyContinue))
            {
                New-PSDrive -Name $script:siteCode -PSProvider CMSite -Root $script:siteServer | Out-Null
            }
            Set-Location "$($script:siteCode):\"
            try
            {
                # Remove existing application
                if (Get-CMApplication -Name $script:vlcAppName -ErrorAction SilentlyContinue)
                {
                    $existingDeps = Get-CMApplicationDeployment -Name $script:vlcAppName -ErrorAction SilentlyContinue
                    foreach ($dep in $existingDeps)
                    {
                        Remove-CMApplicationDeployment -Name $script:vlcAppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
                    }
                    Remove-CMApplication -Name $script:vlcAppName -Force
                    Start-Sleep -Seconds 2
                }

                New-CMApplication `
                    -Name            $script:vlcAppName `
                    -Publisher       $script:vlcAppVendor `
                    -SoftwareVersion $script:vlcAppVersion `
                    -LocalizedName   $script:vlcAppName `
                    -Description     "PSADT v4 VLC template - VLC media player $script:vlcAppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')" | Out-Null

                $installCmd = if (Test-Path (Join-Path $script:vlcPackageDir 'Invoke-AppDeployToolkit.exe'))
                {
                    'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive'
                }
                else
                {
                    'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install'
                }
                $uninstallCmd = if (Test-Path (Join-Path $script:vlcPackageDir 'Invoke-AppDeployToolkit.exe'))
                {
                    'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Interactive'
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
            Where-Object { $_.DisplayName -like '*VLC media player*' -and $_.DisplayVersion -like '3.0.23*' }
    }
}
if ($app) { Write-Host "Installed" }
'@

                Add-CMScriptDeploymentType `
                    -ApplicationName           $script:vlcAppName `
                    -DeploymentTypeName        $script:vlcDTName `
                    -ContentLocation           $script:vlcContentUNC `
                    -InstallCommand            $installCmd `
                    -UninstallCommand          $uninstallCmd `
                    -ScriptLanguage            PowerShell `
                    -ScriptText                $detectScript `
                    -InstallationBehaviorType  InstallForSystem `
                    -LogonRequirementType      WhetherOrNotUserLoggedOn `
                    -RebootBehavior            BasedOnExitCode `
                    -SlowNetworkDeploymentMode Download `
                    -RequireUserInteraction `
                    -MaximumRuntimeMins        30 `
                    -EstimatedRuntimeMins      5 | Out-Null

                $dt = Get-CMDeploymentType -ApplicationName $script:vlcAppName -DeploymentTypeName $script:vlcDTName
                Add-CMDeploymentTypeReturnCode -InputObject $dt -ReturnCode 3010 -CodeType SoftReboot -Name 'Reboot Required' | Out-Null
                Add-CMDeploymentTypeReturnCode -InputObject $dt -ReturnCode 1641 -CodeType HardReboot -Name 'Reboot Initiated' | Out-Null

                $created = Get-CMApplication -Name $script:vlcAppName -ErrorAction SilentlyContinue
                $created | Should -Not -BeNullOrEmpty

                # ----------------------------------------------------------------
                # Step 7 - Distribute content
                # ----------------------------------------------------------------
                Write-Verbose '[VLC] Step 7: Triggering content distribution...'
                $dpGroups = Get-CMDistributionPointGroup -ErrorAction SilentlyContinue
                $dpList = Get-CMDistributionPoint -ErrorAction SilentlyContinue

                if ($dpGroups)
                {
                    foreach ($grp in $dpGroups)
                    {
                        Start-CMContentDistribution -ApplicationName $script:vlcAppName `
                            -DistributionPointGroupName $grp.Name -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                elseif ($dpList)
                {
                    foreach ($dp in $dpList)
                    {
                        Start-CMContentDistribution -ApplicationName $script:vlcAppName `
                            -DistributionPointName $dp.NetworkOSPath.TrimStart('\') -ErrorAction SilentlyContinue | Out-Null
                    }
                }
                else
                {
                    Write-Information '::warning::[VLC] No distribution points or DP groups found - content distribution skipped.' -InformationAction Continue
                }
                # Poll content distribution status every 60 seconds for up to 10 minutes
                $packageId = (Get-CMApplication -Name $script:vlcAppName -ErrorAction SilentlyContinue).PackageID
                if ($packageId)
                {
                    $maxWaitSeconds = 600
                    $pollIntervalSeconds = 60
                    $elapsed = 0
                    $distributionStatus = $null

                    do
                    {
                        $distributionStatus = Get-CMDistributionStatus -Id $packageId -ErrorAction SilentlyContinue
                        if ($distributionStatus)
                        {
                            Write-Verbose "[VLC] Distribution status (elapsed ${elapsed}s): Targeted=$($distributionStatus.Targeted) Success=$($distributionStatus.NumberSuccess) InProgress=$($distributionStatus.NumberInProgress) Errors=$($distributionStatus.NumberErrors)"
                            if ($distributionStatus.NumberSuccess -ge $distributionStatus.Targeted -and $distributionStatus.Targeted -gt 0)
                            {
                                break
                            }
                        }

                        if ($elapsed -lt $maxWaitSeconds)
                        {
                            Write-Verbose "[VLC] Distribution not yet complete - waiting ${pollIntervalSeconds}s before next check..."
                            Start-Sleep -Seconds $pollIntervalSeconds
                            $elapsed += $pollIntervalSeconds
                        }
                        else
                        {
                            break
                        }
                    }
                    while ($elapsed -le $maxWaitSeconds)

                    $distributionStatus | Should -Not -BeNullOrEmpty -Because 'Content distribution status must exist'
                    $distributionStatus.NumberSuccess | Should -Be $distributionStatus.Targeted -Because "All $($distributionStatus.Targeted) targeted distribution points must have received the content successfully (waited up to ${maxWaitSeconds}s)"
                }
                else
                {
                    Write-Information '::warning::[VLC] Could not retrieve PackageID for distribution status check.' -InformationAction Continue
                }

                # ----------------------------------------------------------------
                # Step 7b - Deploy application to collection
                # ----------------------------------------------------------------
                Write-Verbose "[VLC] Step 7b: Deploying application to collection '$($script:targetCollection)'..."

                # Validate collection exists if not using default
                if ($script:targetCollection -ne 'All Systems')
                {
                    $col = Get-CMDeviceCollection -Name $script:targetCollection -ErrorAction SilentlyContinue
                    $col | Should -Not -BeNullOrEmpty -Because "Collection '$($script:targetCollection)' must exist in SCCM"
                    Write-Verbose "[VLC] Collection validated: $($script:targetCollection) ($($col.MemberCount) device(s))"
                }

                # Remove existing deployment before recreating
                $existDeploy = Get-CMApplicationDeployment -Name $script:vlcAppName -CollectionName $script:targetCollection -ErrorAction SilentlyContinue
                if ($existDeploy)
                {
                    Remove-CMApplicationDeployment -Name $script:vlcAppName -CollectionName $script:targetCollection -Force -ErrorAction SilentlyContinue
                    Write-Verbose "[VLC] Removed existing deployment: $($script:vlcAppName) -> $($script:targetCollection)"
                }

                New-CMApplicationDeployment `
                    -Name                       $script:vlcAppName `
                    -CollectionName             $script:targetCollection `
                    -DeployAction               Install `
                    -DeployPurpose              Required `
                    -UserNotification           DisplaySoftwareCenterOnly `
                    -TimeBaseOn                 LocalTime `
                    -OverrideServiceWindow      $false `
                    -RebootOutsideServiceWindow $false | Out-Null

                $createdDeploy = Get-CMApplicationDeployment -Name $script:vlcAppName -CollectionName $script:targetCollection -ErrorAction SilentlyContinue
                $createdDeploy | Should -Not -BeNullOrEmpty -Because "Deployment of '$($script:vlcAppName)' to '$($script:targetCollection)' must be created successfully"
                Write-Verbose "[VLC] Deployment created: $($script:vlcAppName) -> $($script:targetCollection) (Required)"

                # ----------------------------------------------------------------
                # Step 8 - Poll application deployment status
                # ----------------------------------------------------------------
                Write-Information '[VLC] Step 8: Polling application deployment status...' -InformationAction Continue
                $deploymentSummary = Invoke-WinSCPPollDeploymentStatus `
                    -AppName        $script:vlcAppName `
                    -SiteCode       $script:siteCode `
                    -Label          'Deployment' `
                    -MaxWaitSeconds 3600 `
                    -PollInterval   180
                $deploymentSummary | Should -Not -BeNullOrEmpty -Because 'Application deployment status must exist'
                # write $deploymentSummary
                Write-Information $deploymentSummary -InformationAction Continue
                $deploymentSummary.NumberSuccess | Should -BeGreaterThan 0 -Because 'At least one device must have successfully deployed the application (waited up to 3600s)'
                $script:vlcInstallDeploySucceeded = $true
            }
            finally
            {
                if ($script:VLCSiteOriginalLocation)
                {
                    Set-Location $script:VLCSiteOriginalLocation
                }
            }
        }

        It 'Creates uninstall deployment after VLC install deployment succeeds' {
            if (-not $script:vlcInstallDeploySucceeded)
            {
                Set-ItResult -Skipped -Because "Prerequisite test 'Builds VLC package and imports into SCCM' did not complete successfully"
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

            if ([string]::IsNullOrWhiteSpace($script:siteCode))
            {
                throw "siteCode cannot be null or empty"
            }
            if ([string]::IsNullOrWhiteSpace($script:siteServer))
            {
                throw "siteServer cannot be null or empty"
            }
            Import-Module $script:cmModulePath -ErrorAction Stop
            $script:VLCSiteOriginalLocation = Get-Location
            if (-not (Get-PSDrive -Name $script:siteCode -ErrorAction SilentlyContinue))
            {
                New-PSDrive -Name $script:siteCode -PSProvider CMSite -Root $script:siteServer | Out-Null
            }
            Set-Location "$($script:siteCode):\"
            try
            {
                $app = Get-CMApplication -Name $script:vlcAppName -ErrorAction SilentlyContinue
                $app | Should -Not -BeNullOrEmpty -Because 'VLC application must exist before creating uninstall deployment'

                $existingDeployments = Get-CMApplicationDeployment -Name $script:vlcAppName -CollectionName $script:targetCollection -ErrorAction SilentlyContinue
                foreach ($dep in $existingDeployments)
                {
                    Remove-CMApplicationDeployment -Name $script:vlcAppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
                    Write-Information "Removed existing deployment for '$($script:vlcAppName)' to collection '$($dep.CollectionName)'" -InformationAction Continue
                }
                Start-Sleep -Seconds 2

                New-CMApplicationDeployment `
                    -Name                       $script:vlcAppName `
                    -CollectionName             $script:targetCollection `
                    -DeployAction               Uninstall `
                    -DeployPurpose              Required `
                    -UserNotification           DisplaySoftwareCenterOnly `
                    -TimeBaseOn                 LocalTime `
                    -OverrideServiceWindow      $false `
                    -RebootOutsideServiceWindow $false | Out-Null

                $uninstallDeploy = Get-CMApplicationDeployment -Name $script:vlcAppName -CollectionName $script:targetCollection -ErrorAction SilentlyContinue
                $uninstallDeploy | Should -Not -BeNullOrEmpty -Because "Uninstall deployment of '$($script:vlcAppName)' to '$($script:targetCollection)' must be created successfully"
                Write-Information "[VLC] Uninstall deployment created: $($script:vlcAppName) -> $($script:targetCollection) (Required)" -InformationAction Continue

                # ----------------------------------------------------------------
                # Step 9 - Poll uninstall deployment status
                # ----------------------------------------------------------------
                Write-Information '[VLC] Step 9: Polling uninstall deployment status...' -InformationAction Continue
                $uninstallSummary = Invoke-WinSCPPollDeploymentStatus `
                    -AppName        $script:vlcAppName `
                    -SiteCode       $script:siteCode `
                    -Label          'Uninstall deployment' `
                    -MaxWaitSeconds 3600 `
                    -PollInterval   180
                $uninstallSummary | Should -Not -BeNullOrEmpty -Because 'Uninstall deployment status must exist'
                $uninstallSummary.NumberSuccess | Should -BeGreaterThan 0 -Because 'At least one device must have successfully uninstalled the application (waited up to 3600s)'
            }
            finally
            {
                if ($script:VLCSiteOriginalLocation)
                {
                    Set-Location $script:VLCSiteOriginalLocation
                }
            }
        }
    }
}