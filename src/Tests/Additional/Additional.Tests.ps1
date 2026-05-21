Describe 'Additional Tests' {
    Context 'Sanity checks' {
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