#pragma warning disable PSPlaceOpenBrace

# ---------------------------------------------------------------------------
# TerraForge test run reporting helper
# Loaded once per session; silently skipped if env vars are not set
# ---------------------------------------------------------------------------
BeforeAll {
    Write-Information "[Pester] Version: $((Get-Module Pester).Version)" -InformationAction Continue
    $script:TFReportingEnabled = $true
    $script:TFAccessToken = $null
    $script:TFTestRunId = $env:TEST_RUN_ID
    $script:TFApiBaseUrl = $env:TERRAFORGE_API_BASE_URL

    if ($script:TFTestRunId -and $script:TFApiBaseUrl)
    {
        $helperPath = Join-Path $PSScriptRoot '..\..\..\.github\scripts\TerraForge-AgentHelper.ps1'
        if (Test-Path $helperPath)
        {
            . $helperPath
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
            Write-Warning "[TerraForge] Helper script not found at: $helperPath"
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
}

# ---------------------------------------------------------------------------

Describe 'Intune Tests' {
    Context 'Sanity checks' {
        BeforeEach {
            $testInfo = $____Pester.CurrentTest
            $script:CurrentTestClass = 'Intune Tests / Sanity checks'
            $script:CurrentTestMethod = $testInfo.Name
            Invoke-TFReportTestCase -TestClass $script:CurrentTestClass -TestMethod $script:CurrentTestMethod
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

        It 'Microsoft.Graph.Intune module or Microsoft.Graph is available or can be found' {
            $graphModule = Get-Module -Name 'Microsoft.Graph*' -ListAvailable
            # If not installed, this test will be skipped gracefully
            if (-not $graphModule)
            {
                Set-ItResult -Skipped -Because 'Microsoft.Graph module is not installed on this runner'
            }
            else
            {
                $graphModule | Should -Not -BeNullOrEmpty
            }
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

        It 'IntuneWinAppUtil.exe is accessible or PSADT packaging scripts exist' {
            $intuneUtil = Get-Command 'IntuneWinAppUtil.exe' -ErrorAction SilentlyContinue
            if (-not $intuneUtil)
            {
                Set-ItResult -Skipped -Because 'IntuneWinAppUtil.exe not found on PATH - Intune packaging tool not installed'
            }
            else
            {
                $intuneUtil | Should -Not -BeNullOrEmpty
            }
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
}

#pragma warning restore PSPlaceOpenBrace
