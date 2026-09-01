#pragma warning disable PSPlaceOpenBrace
<#
.SYNOPSIS
    Returns the array of shared app configurations used by Additional and Intune tests.
.DESCRIPTION
    Uses the Intune-style array/hashtable format and includes additional fields
    required by SCCM Additional tests.
#>

$sharedEnvironmentHelpersPath = Join-Path $PSScriptRoot 'TestAppEnvironment.Helpers.ps1'
if (-not (Test-Path -LiteralPath $sharedEnvironmentHelpersPath -PathType Leaf))
{
    throw "Required shared helper file not found: $sharedEnvironmentHelpersPath"
}
if (-not (Get-Command -Name 'Initialize-NotepadPlusPlusLegacyTestEnvironment' -CommandType Function -ErrorAction SilentlyContinue))
{
    . $sharedEnvironmentHelpersPath
}

@(
    @{
        Name = 'VLC'
        TemplateVersion = 'V4'
        AppFolderName = 'VLC'
        SourceFolderRelativePath = 'VLC'
        AppName = 'VLC media player (PSADT v4 VLC)'
        AppVendor = 'VideoLAN'
        AppVersion = '3.0.23'
        RegDisplayName = 'VLC media player'
        RegVersionValue = '3.0.23'
        InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive'
        UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Interactive'
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
        AppName = 'WinSCP (PSADT v4 winSCP)'
        AppVendor = 'Martin Prikryl'
        AppVersion = '6.5.6'
        ContentSubPath = 'winSCP'
        RegVersionValue = '6.5.6'
        InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive'
        UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Interactive'
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
        AppName = 'Notepad++ (PSADT v4 Notepad++)'
        AppVendor = 'Don HO don.h@free.fr'
        AppVersion = '8.9.8'
        ContentSubPath = 'NotepadPlusPlus'
        InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive'
        UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Interactive'
        RegVersionValue = '8.9.8'
        VersionCheckFilePath = 'C:\Program Files (x86)\Notepad++\notepad++.exe'
        ExpectedDeferralFileVersionPattern = '^8\.9\.7(\.|$)'
        ExpectedDeferralFileVersionDescription = 'legacy version 8.9.7'
        PreInstallScript = {
            Initialize-NotepadPlusPlusLegacyTestEnvironment -LaunchLegacyProcess -LogPrefix 'Notepad++'
        }
        PostInstallScript = {
            $notepadExePath = 'C:\Program Files (x86)\Notepad++\notepad++.exe'
            if (Test-Path $notepadExePath)
            {
                $notepadFileVersion = (Get-Item -Path $notepadExePath).VersionInfo.FileVersion
                Write-Information "[Notepad++] FileVersion: $notepadFileVersion" -InformationAction Continue
                if ($notepadFileVersion -match '^8\.9\.7(\.|$)')
                {
                    Write-Information '[Notepad++] The currently retained version is the legacy version (8.9.7).' -InformationAction Continue
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
                -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '8.9.8'
        }
    }
    @{
        Name = '7-Zip ForceClose'
        TemplateVersion = 'V4'
        AppFolderName = '7-Zip ForceClose'
        AppName = '7-Zip ForceClose (PSADT v4)'
        AppVendor = 'Igor Pavlov'
        AppVersion = '24.09'
        ContentSubPath = 'SevenZipForceClose'
        TargetInstallerDir = 'C:\Tools\Intune\SevenZipForceClose'
        TargetInstallerName = '7z2409-x64.msi'
        TargetInstallerUri = 'https://www.7-zip.org/a/7z2409-x64.msi'
        InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
        UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
        RegDisplayName = '7-Zip'
        RegVersionValue = '24.09'
        DetectionRuleBuilder = {
            param($FilesDir)
            $msiFile = Get-ChildItem -Path $FilesDir -Filter '7z2409-x64.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $msiFile) { throw 'No MSI file found for 7-Zip detection rule' }
            $productCode = Get-MsiProductCode -MsiPath $msiFile.FullName
            New-IntuneWin32AppDetectionRuleMSI -ProductCode $productCode
        }
        PreInstallScript = {
            Initialize-SevenZipForceCloseTestEnvironment -LaunchProcess -LogPrefix '7-Zip ForceClose'
        }
        PreUninstallScript = {
            $sevenZipFileManager = Join-Path ${env:ProgramFiles} '7-Zip\7zFM.exe'
            Start-PSADTTestAppProcess -FilePath $sevenZipFileManager -ProcessName '7zFM' -Description 'installed 7zFM' -LogPrefix '7-Zip ForceClose'
        }
        PostInstallScript = {
            $sevenZipEntries = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            ) | ForEach-Object {
                Get-ItemProperty -Path $PSItem -ErrorAction SilentlyContinue | Where-Object { $PSItem.DisplayName -like '7-Zip*' }
            }
            if ($sevenZipEntries)
            {
                $sevenZipEntries | ForEach-Object {
                    Write-Information "[7-Zip ForceClose] Installed 7-Zip entry: $($PSItem.DisplayName) $($PSItem.DisplayVersion)" -InformationAction Continue
                }
            }
            else
            {
                Write-Warning '[7-Zip ForceClose] 7-Zip uninstall registry entry was not found after install.'
            }
        }
    }
    @{
        Name = 'Digiexam'
        TemplateVersion = 'V3'
        AppFolderName = 'Digiexam'
        AppName = 'Digiexam (PSADT v3 Digiexam)'
        AppVendor = 'DigiExam'
        AppVersion = '26.1.24'
        ContentSubPath = 'DigiExam'
        InstallerSourceFile = 'C:\Tools\Intune\Digiexam_26.1.24_x64_en-US.msi'
        RegVersionValue = '26.1.24'
        InstallCmd = "Deploy-Application.exe -DeploymentType 'Install'"
        UninstallCmd = "Deploy-Application.exe -DeploymentType 'Uninstall'"
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
        AppName = 'Everything (PSADT v3 Everything)'
        AppVendor = 'voidtools'
        AppVersion = '1.4.1.1032'
        InstallerSourceFile = 'C:\Tools\Intune\Everything-1.4.1.1032.x64-Setup.exe'
        RegDisplayName = 'Everything 1.4.1.1032'
        RegVersionValue = '1.4.1.1032'
        InstallCmd = "Deploy-Application.exe -DeploymentType 'Install'"
        UninstallCmd = "Deploy-Application.exe -DeploymentType 'Uninstall'"
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
