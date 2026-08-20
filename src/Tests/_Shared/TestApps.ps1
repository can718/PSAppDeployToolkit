#pragma warning disable PSPlaceOpenBrace
<#
.SYNOPSIS
    Returns the array of shared app configurations used by Additional and Intune tests.
.DESCRIPTION
    Uses the Intune-style array/hashtable format and includes additional fields
    required by SCCM Additional tests.
#>

$notepadPlusPlusStateBackupScript = {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $backupRoot = 'C:\PSADT\NotepadPlusPlusState'
    New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

    $notepadExePath = Join-Path ${env:ProgramFiles(x86)} 'Notepad++\notepad++.exe'
    $notepadProcesses = @(Get-Process -Name 'notepad++' -ErrorAction SilentlyContinue)
    $registryRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $registryMatches = foreach ($registryRoot in $registryRoots)
    {
        Get-ChildItem -Path $registryRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $properties = Get-ItemProperty -Path $PSItem.PSPath -ErrorAction SilentlyContinue
            if ($properties -and $properties.DisplayName -like 'Notepad++*')
            {
                [ordered]@{
                    Path = $PSItem.PSPath
                    DisplayName = $properties.DisplayName
                    DisplayVersion = $properties.DisplayVersion
                }
            }
        }
    }

    $fileVersion = $null
    $productVersion = $null
    if (Test-Path -LiteralPath $notepadExePath -PathType Leaf)
    {
        $versionInfo = (Get-Item -LiteralPath $notepadExePath).VersionInfo
        $fileVersion = $versionInfo.FileVersion
        $productVersion = $versionInfo.ProductVersion
    }

    $state = [ordered]@{
        Timestamp = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        AppName = $AppName
        Phase = $Phase
        ProcessRunning = ($notepadProcesses.Count -gt 0)
        ProcessIds = @($notepadProcesses | ForEach-Object { $PSItem.Id })
        ExePath = $notepadExePath
        ExeExists = (Test-Path -LiteralPath $notepadExePath -PathType Leaf)
        FileVersion = $fileVersion
        ProductVersion = $productVersion
        Registry = @($registryMatches)
    }

    $safeAppName = ([regex]::Replace($AppName, '[^A-Za-z0-9._-]+', '_')).Trim('_')
    $safePhase = ([regex]::Replace($Phase, '[^A-Za-z0-9._-]+', '_')).Trim('_')
    $backupPath = Join-Path $backupRoot ('{0}_{1}_{2}.json' -f $safeAppName, $safePhase, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8
    Write-Information "[$AppName] Saved Notepad++ state backup [$Phase]: $backupPath" -InformationAction Continue
}

$notepadPlusPlusProcessEnsureScript = {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    if (Get-Process -Name 'notepad++' -ErrorAction SilentlyContinue)
    {
        Write-Information "[$AppName] Notepad++ process is already running." -InformationAction Continue
        return
    }

    $notepadExePath = Join-Path ${env:ProgramFiles(x86)} 'Notepad++\notepad++.exe'
    if (Test-Path -LiteralPath $notepadExePath -PathType Leaf)
    {
        Write-Information "[$AppName] Starting Notepad++ process before deployment." -InformationAction Continue
        Start-Process -FilePath $notepadExePath
        Start-Sleep -Seconds 3
    }
    else
    {
        Write-Warning "[$AppName] Launch path not found: $notepadExePath"
    }
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
        SkipIntune = $true
        SkipUninstall = $true
        TemplateVersion = 'V4'
        AppFolderName = 'Notepad++'
        AppName = 'Notepad++ (PSADT v4 Notepad++)'
        AppVendor = 'Don HO don.h@free.fr'
        AppVersion = '6.6.4'
        ContentSubPath = 'NotepadPlusPlus'
        InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
        UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
        RegVersionValue = '6.6.4'
        VersionCheckFilePath = 'C:\Program Files (x86)\Notepad++\notepad++.exe'
        StateBackupScript = $notepadPlusPlusStateBackupScript.GetNewClosure()
        ExpectedDeferralFileVersionPattern = '^(6\.23|6\.2\.3)(\.|$)'
        ExpectedDeferralFileVersionDescription = 'legacy version 6.2.3'
        PreInstallScript = ({
            # Install lower version as prerequisite for upgrade test.
            $installerDir = 'C:\Tools\Intune\Notepad6.2.3'
            $installerPath = Join-Path $installerDir 'npp.6.2.3.Installer.exe'
            if (-not (Test-Path $installerPath))
            {
                New-Item -Path $installerDir -ItemType Directory -Force | Out-Null
                Invoke-WebRequest -Uri 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-2/npp.6.2.3.Installer.exe' -OutFile $installerPath -UseBasicParsing
            }
            Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -NoNewWindow
            & $notepadPlusPlusProcessEnsureScript -AppName 'Notepad++'
            & $notepadPlusPlusStateBackupScript -AppName 'Notepad++' -Phase 'BeforeInstall'

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
        }).GetNewClosure()
        PostInstallScript = ({
            & $notepadPlusPlusStateBackupScript -AppName 'Notepad++' -Phase 'PostInstall'
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
        }).GetNewClosure()
        DetectionRuleBuilder = {
            param($FilesDir)
            $null = $FilesDir
            New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++' `
                -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '6.6.4'
        }
    }
    @{
        Name = 'Notepad++ ForceClose'
        SkipUninstall = $true
        TemplateVersion = 'V4'
        AppFolderName = 'Notepad++ ForceClose'
        AppName = 'Notepad++ (PSADT v4 Notepad++ ForceClose)'
        AppVendor = 'Don HO don.h@free.fr'
        AppVersion = '6.8.8'
        ContentSubPath = 'NotepadPlusPlusForceClose'
        TargetInstallerDir = 'C:\Tools\SCCM\NotepadPlusPlus\6.8.8'
        TargetInstallerName = 'npp.6.8.8.Installer.exe'
        TargetInstallerUri = 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-7/npp.6.8.8.Installer.exe'
        RegDisplayName = 'Notepad++'
        InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
        UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
        RegVersionValue = '6.8.8'
        VersionCheckFilePath = 'C:\Program Files (x86)\Notepad++\notepad++.exe'
        StateBackupScript = $notepadPlusPlusStateBackupScript.GetNewClosure()
        ExpectedInstallFileVersionPattern = '^6\.8\.8(\.|$)'
        ExpectedInstallFileVersionDescription = '6.8.8'
        PreInstallScript = ({
            # Install lower version as prerequisite for upgrade test.
            $installerDir = 'C:\Tools\Intune\Notepad6.2.3'
            $installerPath = Join-Path $installerDir 'npp.6.2.3.Installer.exe'
            if (-not (Test-Path $installerPath))
            {
                New-Item -Path $installerDir -ItemType Directory -Force | Out-Null
                Invoke-WebRequest -Uri 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-2/npp.6.2.3.Installer.exe' -OutFile $installerPath -UseBasicParsing
            }
            Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -NoNewWindow
            & $notepadPlusPlusProcessEnsureScript -AppName 'Notepad++ ForceClose'
            & $notepadPlusPlusStateBackupScript -AppName 'Notepad++ ForceClose' -Phase 'BeforeInstall'

            # Download new version installer.
            $newDir = 'C:\Tools\Intune\Notepad6.8.8'
            $newPath = Join-Path $newDir 'npp.6.8.8.Installer.exe'
            if (-not (Test-Path $newPath))
            {
                New-Item -Path $newDir -ItemType Directory -Force | Out-Null
                Invoke-WebRequest -Uri 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-7/npp.6.8.8.Installer.exe' -OutFile $newPath -UseBasicParsing
            }

            # Keep a copy at the V4 template default file path.
            $templateExpectedInstallerPath = 'C:\Tools\Intune\npp.6.8.8.Installer.exe'
            Copy-Item -Path $newPath -Destination $templateExpectedInstallerPath -Force
        }).GetNewClosure()
        PostInstallScript = ({
            & $notepadPlusPlusStateBackupScript -AppName 'Notepad++ ForceClose' -Phase 'PostInstall'
            $notepadExePath = 'C:\Program Files (x86)\Notepad++\notepad++.exe'
            if (Test-Path $notepadExePath)
            {
                $notepadFileVersion = (Get-Item -Path $notepadExePath).VersionInfo.FileVersion
                Write-Information "[Notepad++ ForceClose] FileVersion: $notepadFileVersion" -InformationAction Continue
                if ($notepadFileVersion -match '^6\.8\.8(\.|$)')
                {
                    Write-Information '[Notepad++ ForceClose] The expected target version is installed (6.8.8).' -InformationAction Continue
                }
                else
                {
                    Write-Warning "[Notepad++ ForceClose] Main exe version is not the expected target value: $notepadFileVersion"
                }
            }
            else
            {
                Write-Information "[Notepad++ ForceClose] File not found at: $notepadExePath" -InformationAction Continue
            }
        }).GetNewClosure()
        DetectionRuleBuilder = {
            param($FilesDir)
            $null = $FilesDir
            New-IntuneWin32AppDetectionRuleRegistry -StringComparison `
                -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++' `
                -ValueName 'DisplayVersion' -StringComparisonOperator 'equal' -StringComparisonValue '6.8.8'
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
