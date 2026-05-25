# ---------------------------------------------------------------------------
# TerraForge test run reporting helper
# Loaded once per session; silently skipped if env vars are not set
# ---------------------------------------------------------------------------
BeforeAll {
    Write-Host "[Pester] Version: $((Get-Module Pester).Version)"
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
            [string]$TestMethod
        )
        $script:TFCurrentResultId = $null
        if (-not $script:TFReportingEnabled) { return }

        if ([string]::IsNullOrWhiteSpace($TestMethod)) {
            Write-Warning "[TerraForge] Skipping result entry creation: could not resolve test name."
            return
        }

        try {
            $result = New-TestRunResults `
                -ApiBaseUrl  $script:TFApiBaseUrl `
                -AccessToken $script:TFAccessToken `
                -TestRunId   $script:TFTestRunId `
                -TestClass   $TestClass `
                -SessionId   $env:TEST_SESSION_ID `
                -ProductName $TestMethod
            $script:TFCurrentResultId = $result.Id
            Write-Host "[TerraForge] Created result entry Id=$($result.Id) for: $TestClass / $TestMethod"
        } catch {
            Write-Warning "[TerraForge] Failed to create result entry for '$TestMethod': $($_.Exception.Message)"
        }
    }

    function script:Invoke-TFUpdateTestCase {
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
        try {
            # $TestResult.Result is still "Running" inside AfterEach.
            # Derive outcome: Skipped flag is set before AfterEach runs;
            # ErrorRecord accumulates test body errors before AfterEach runs.
            $resultCode = if ($TestResult.Skipped) {
                4   # Skipped
            } elseif ($TestResult.ErrorRecord -and $TestResult.ErrorRecord.Count -gt 0) {
                0   # Failed
            } else {
                2   # Passed
            }
            $errorMsg = if ($TestResult.ErrorRecord -and $TestResult.ErrorRecord.Count -gt 0) {
                $TestResult.ErrorRecord[0].Exception.Message
            } else {
                $null
            }

            Update-TestRunResults `
                -ApiBaseUrl       $script:TFApiBaseUrl `
                -AccessToken      $script:TFAccessToken `
                -TestRunResultId  $script:TFCurrentResultId `
                -Result           $resultCode `
                -ErrorMessage     $errorMsg
            Write-Verbose "[TerraForge] Updated result Id=$($script:TFCurrentResultId) → code=$resultCode"
        } catch {
            Write-Warning "[TerraForge] Failed to update result Id=$($script:TFCurrentResultId): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------

Describe 'Additional Tests' {
    Context 'Sanity checks' {
        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass  = 'Additional Tests / Sanity checks'
            $script:CurrentTestMethod = $testInfo.Name
            Write-Host "[BeforeEach] TestClass: $($script:CurrentTestClass)"
            Write-Host "[BeforeEach] TestMethod: $($script:CurrentTestMethod)"
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
            $script:CurrentTestClass  = 'PSADT Build Template Validation / Template paths from build output'
            $script:CurrentTestMethod = $testInfo.Name
            Write-Host "[BeforeEach] TestClass: $($script:CurrentTestClass)"
            Write-Host "[BeforeEach] TestMethod: $($script:CurrentTestMethod)"
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
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass  = 'Deploy-WithPSADT-ToSCCM / SCCM deployment using build output templates'
            $script:CurrentTestMethod = $testInfo.Name
            Write-Host "[BeforeEach] TestClass: $($script:CurrentTestClass)"
            Write-Host "[BeforeEach] TestMethod: $($script:CurrentTestMethod)"
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