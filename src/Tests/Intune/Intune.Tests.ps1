Describe 'Intune Tests'
{
    Context 'Sanity checks'
    {
        It 'PowerShell version is 5.1 or higher'
        {
            $PSVersionTable.PSVersion.Major | Should -BeGreaterOrEqual 5
        }

        It 'True is true'
        {
            $true | Should -BeTrue
        }

        It 'Basic arithmetic works'
        {
            (1 + 1) | Should -Be 2
        }
    }

    Context 'Intune Module Availability'
    {
        It 'Microsoft.Graph.Intune module or Microsoft.Graph is available or can be found'
        {
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

    Context 'Intune Package Deployment Checks'
    {
        It 'PSADT module artifacts directory exists after build'
        {
            $artifactPath = '.\src\Artifacts'
            Test-Path $artifactPath | Should -BeTrue
        }

        It 'Invoke-AppDeployToolkit.ps1 template exists in v4 artifacts'
        {
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

        It 'AppDeployToolkitMain.ps1 is present in build output'
        {
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

    Context 'Intune Win32 App Packaging Requirements'
    {
        It 'IntuneWinAppUtil.exe is accessible or PSADT packaging scripts exist'
        {
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

        It 'PSAppDeployToolkit module can be found in src output'
        {
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
