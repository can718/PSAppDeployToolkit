# ---------------------------------------------------------------------------
# TerraForge test run reporting helper
# Loaded once per session; silently skipped if env vars are not set
# ---------------------------------------------------------------------------
BeforeAll {
    $script:TFReportingEnabled = $false
    $script:TFAccessToken      = $null
    $script:TFTestRunId        = $env:TEST_RUN_ID
    $script:TFApiBaseUrl       = $env:TERRAFORGE_API_BASE_URL

    if ($script:TFTestRunId -and $script:TFApiBaseUrl) {
        $helperPath = Join-Path $PSScriptRoot '..\..\..\.github\scripts\TerraForge-AgentHelper.ps1'
        if (Test-Path $helperPath) {
            . $helperPath
            try {
                $script:TFAccessToken = Get-TerraForgeAuthToken `
                    -ManagedIdentityClientId $env:INFRA_MI_CLIENT_ID `
                    -KeyVaultName            $env:INFRA_KEYVAULT `
                    -ApiKeySecretName        $env:TERRAFORGE_API_KEY_SECRET `
                    -ApiBaseUrl              $script:TFApiBaseUrl
                $script:TFReportingEnabled = $true
                Write-Host "[TerraForge] Reporting enabled for TestRunId: $script:TFTestRunId"
            } catch {
                Write-Warning "[TerraForge] Could not obtain access token, reporting disabled: $($_.Exception.Message)"
            }
        } else {
            Write-Warning "[TerraForge] Helper script not found at: $helperPath"
        }
    }

    function script:Invoke-TFReportTestCase {
        <#
            Creates a test run result entry before the test executes.
            Stores the returned ID in $script:TFCurrentResultId for AfterEach to update.
        #>
        param (
            [string]$TestClass,
            [object]$PesterTest
        )
        $script:TFCurrentResultId = $null
        if (-not $script:TFReportingEnabled) { return }

        # Resolve test name: ExpandedName → Name → FullyQualifiedName → fallback
        $testName = $PesterTest.ExpandedName
        if ([string]::IsNullOrWhiteSpace($testName)) { $testName = $PesterTest.Name }
        if ([string]::IsNullOrWhiteSpace($testName)) { $testName = $PesterTest.FullyQualifiedName }
        if ([string]::IsNullOrWhiteSpace($testName)) {
            Write-Warning "[TerraForge] Skipping result entry creation: could not resolve test name from PesterTest object."
            return
        }

        try {
            $result = New-TestRunResults `
                -ApiBaseUrl  $script:TFApiBaseUrl `
                -AccessToken $script:TFAccessToken `
                -TestRunId   $script:TFTestRunId `
                -MachineId   $env:COMPUTERNAME `
                -TestClass   $TestClass `
                -SessionId   $env:TEST_SESSION_ID `
                -ProductName $testName
            $script:TFCurrentResultId = $result.Id
            Write-Verbose "[TerraForge] Created result entry Id=$($result.Id) for: $TestClass / $testName"
        } catch {
            Write-Warning "[TerraForge] Failed to create result entry for '$testName': $($_.Exception.Message)"
        }
    }

    function script:Invoke-TFUpdateTestCase {
        <#
            Updates the test run result after the test completes.
            Result codes: 1 = Passed, 2 = Failed, 4 = Skipped
        #>
        param (
            [object]$TestResult
        )
        if (-not $script:TFReportingEnabled -or -not $script:TFCurrentResultId) { return }
        try {
            $resultCode = switch ($TestResult.Result) {
                'Passed'  { 2 } # Passed
                'Failed'  { 0 } # Failed
                'Skipped' { 4 } # Skipped
                default   { 3 } # Unknown → treat as Failed
            }
            $errorMsg = if ($TestResult.ErrorRecord) { $TestResult.ErrorRecord.Exception.Message } else { $null }

            Update-TestRunResults `
                -ApiBaseUrl       $script:TFApiBaseUrl `
                -AccessToken      $script:TFAccessToken `
                -TestRunResultId  $script:TFCurrentResultId `
                -Result           $resultCode `
                -ErrorMessage     $errorMsg
            Write-Verbose "[TerraForge] Updated result Id=$($script:TFCurrentResultId) → $($TestResult.Result)"
        } catch {
            Write-Warning "[TerraForge] Failed to update result Id=$($script:TFCurrentResultId): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------

Describe 'Additional Tests' {
    Context 'Sanity checks' {
        BeforeEach {
            Invoke-TFReportTestCase -TestClass 'Additional Tests / Sanity checks' -PesterTest $PSItem
        }
        AfterEach {
            Invoke-TFUpdateTestCase -TestResult $PSItem
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
            Invoke-TFReportTestCase -TestClass 'PSADT Build Template Validation / Template paths from build output' -PesterTest $PSItem
        }
        AfterEach {
            Invoke-TFUpdateTestCase -TestResult $PSItem
        }

        It 'PSADT_TEMPLATE_V3_DIR environment variable is set' {
            $script:v3Dir | Should -Not -BeNullOrEmpty
        }

        It 'PSADT_TEMPLATE_V4_DIR environment variable is set' {
            $script:v4Dir | Should -Not -BeNullOrEmpty
        }

        It 'V3 template directory exists on disk' {
            if (-not $script:v3Dir) { Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V3_DIR not set'; return }
            Test-Path $script:v3Dir | Should -BeTrue
        }

        It 'V4 template directory exists on disk' {
            if (-not $script:v4Dir) { Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V4_DIR not set'; return }
            Test-Path $script:v4Dir | Should -BeTrue
        }

        It 'V3 template contains AppDeployToolkit subfolder' {
            if (-not $script:v3Dir) { Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V3_DIR not set'; return }
            # Search recursively - zip may extract into a subdirectory
            $found = Get-ChildItem -Path $script:v3Dir -Directory -Filter 'AppDeployToolkit' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            $found | Should -Not -BeNullOrEmpty
        }

        It 'V4 template contains Invoke-AppDeployToolkit.ps1' {
            if (-not $script:v4Dir) { Set-ItResult -Skipped -Because 'PSADT_TEMPLATE_V4_DIR not set'; return }
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
            Invoke-TFReportTestCase -TestClass 'Deploy-WithPSADT-ToSCCM / SCCM deployment using build output templates' -PesterTest $PSItem
        }
        AfterEach {
            Invoke-TFUpdateTestCase -TestResult $PSItem
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