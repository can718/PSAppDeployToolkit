#pragma warning disable PSPlaceOpenBrace
<#
.SYNOPSIS
    Returns the array of app configurations used in parallel install/uninstall tests.
.DESCRIPTION
    Extracted to a separate file so it can be sourced during both Pester 5 Discovery
    (for -ForEach) and Run phase (for runtime iteration in It blocks).
#>
@(
    @{
        Name = 'VLC'
        TemplateVersion = 'V4'
        AppFolderName = 'VLC'
        RegDisplayName = 'VLC media player'
        RegVersionValue = '3.0.23'
        RegVersionName = 'DisplayVersion'
        DetectionRuleBuilder = {
            param($FilesDir)
            $null = $FilesDir
            New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VLC media player' `
                -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '3.0.23'
        }
    }
    @{
        Name = 'WinSCP'
        TemplateVersion = 'V4'
        AppFolderName = 'WinSCP'
        RegDisplayName = 'WinSCP'
        RegVersionValue = '6.5.6'
        RegVersionName = 'DisplayVersion'
        DetectionRuleBuilder = {
            param($FilesDir)
            $msiFile = Get-ChildItem -Path $FilesDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $msiFile) { throw 'No MSI file found for WinSCP detection rule' }
            $productCode = Get-MsiProductCode -MsiPath $msiFile.FullName
            New-IntuneWin32AppDetectionRuleMSI -ProductCode $productCode
        }
    }
    @{
        Name = 'Notepad++'
        SkipUninstall = $true
        TemplateVersion = 'V4'
        AppFolderName = 'Notepad++'
        InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
        UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
        RegDisplayName = 'Notepad++'
        RegVersionValue = '6.6.4'
        RegVersionName = 'DisplayVersion'
        PreInstallScript = {
            # Install lower version as prerequisite for upgrade test.
            $installerDir = 'C:\Tools\Intune\Notepad6.2.3'
            $installerPath = Join-Path $installerDir 'npp.6.2.3.Installer.exe'
            if (-not (Test-Path $installerPath))
            {
                New-Item -Path $installerDir -ItemType Directory -Force | Out-Null
                Invoke-WebRequest -Uri 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-2/npp.6.2.3.Installer.exe' -OutFile $installerPath -UseBasicParsing
            }
            Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -NoNewWindow
            $legacyNotepadExePath = Join-Path ${env:ProgramFiles(x86)} 'Notepad++\notepad++.exe'
            if (Test-Path $legacyNotepadExePath)
            {
                Start-Process -FilePath $legacyNotepadExePath
            }
            else
            {
                Write-Warning "[Notepad++] Launch path not found: $legacyNotepadExePath"
            }

            # Download new version installer.
            $newDir = 'C:\Tools\Intune\Notepad6.6.4'
            $newPath = Join-Path $newDir 'npp.6.6.4.Installer.exe'
            if (-not (Test-Path $newPath))
            {
                New-Item -Path $newDir -ItemType Directory -Force | Out-Null
                Invoke-WebRequest -Uri 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-5/npp.6.6.4.Installer.exe' -OutFile $newPath -UseBasicParsing
            }

            # Keep a copy at the V4 template default file path.
            $templateExpectedInstallerPath = 'C:\Tools\Intune\npp.6.6.4.Installer.exe'
            Copy-Item -Path $newPath -Destination $templateExpectedInstallerPath -Force
        }
        PostInstallScript = {
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
        DetectionRuleBuilder = {
            param($FilesDir)
            $null = $FilesDir
            New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++' `
                -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '6.6.4'
        }
    }
    @{
        Name = 'Digiexam'
        TemplateVersion = 'V3'
        AppFolderName = 'Digiexam'
        InstallerSourceFile = 'C:\Tools\Intune\Digiexam_26.1.24_x64_en-US.msi'
        SetupFileName = 'Deploy-Application.exe'
        InstallCmd = "Deploy-Application.exe -DeploymentType 'Install'"
        UninstallCmd = "Deploy-Application.exe -DeploymentType 'Uninstall'"
        RegDisplayName = 'Digiexam'
        RegVersionValue = '26.1.24'
        RegVersionName = 'DisplayVersion'
        DetectionRuleBuilder = {
            param($FilesDir)
            $msiFile = Get-ChildItem -Path $FilesDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $msiFile) { throw 'No MSI file found for Digiexam detection rule' }
            $productCode = Get-MsiProductCode -MsiPath $msiFile.FullName
            New-IntuneWin32AppDetectionRuleMSI -ProductCode $productCode
        }
    }
    @{
        Name = 'Everything'
        TemplateVersion = 'V3'
        AppFolderName = 'Everything'
        InstallerSourceFile = 'C:\Tools\Intune\Everything-1.4.1.1032.x64-Setup.exe'
        SetupFileName = 'Deploy-Application.exe'
        InstallCmd = "Deploy-Application.exe -DeploymentType 'Install'"
        UninstallCmd = "Deploy-Application.exe -DeploymentType 'Uninstall'"
        RegDisplayName = 'Everything 1.4.1.1032'
        RegVersionValue = '1.4.1.1032'
        RegVersionName = 'DisplayVersion'
        DetectionRuleBuilder = {
            param($FilesDir)
            $null = $FilesDir
            New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Everything' `
                -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '1.4.1.1032'
        }
    }
)

#pragma warning restore PSPlaceOpenBrace
