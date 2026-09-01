[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    'NewADTTemplateParameters',
    Justification = 'This hashtable is consumed by external test harness code after the script is loaded.'
)]
$NewADTTemplateParameters = @{
    SessionProperties        = @{
        AppVendor                   = 'Don HO don.h@free.fr'
        AppName                     = 'Notepad++'
        AppVersion                  = '8.9.8'
        AppArch                     = 'x64'
        AppLang                     = 'EN'
        AppRevision                 = '01'
        AppSuccessExitCodes         = @(0)
        AppRebootExitCodes          = @(1641, 3010)
        RequireAdmin                = $true
        AppScriptVersion            = '1.0.0'
        AppScriptDate               = '2026-04-01'
        AppScriptAuthor             = 'PSAppDeployToolkit'
        InstallName                 = ''
        InstallTitle                = ''
        DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
        DeployAppScriptParameters   = $PSBoundParameters
        DeployAppScriptVersion      = '4.2.0'
    }
    Destination              = 'C:\PSADT\NotepadPlusPlus'
    Files                    = 'C:\Tools\Intune\npp.8.9.8.Installer.exe'
    PreInstallScriptBlock    = {
        Start-AdditionalTestRecording

        Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] PreInstall PSADT process: PID=[$PID], User=[$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)], SessionId=[$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)], DeploymentType=[$($adtSession.DeploymentType)], DeployMode=[$($adtSession.DeployMode)]." -Severity Info
        $notepadProcesses = @(Get-Process -Name 'notepad++' -ErrorAction SilentlyContinue)
        if ($notepadProcesses.Count -eq 0)
        {
            Write-ADTLogEntry -Message '[TEMP-VERIFY-NPP-SESSION] PreInstall notepad++ process: none found.' -Severity Warning
        }
        else
        {
            foreach ($notepadProcess in $notepadProcesses)
            {
                Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] PreInstall notepad++ process: PID=[$($notepadProcess.Id)], SessionId=[$($notepadProcess.SessionId)], Path=[$($notepadProcess.Path)]." -Severity Info
            }
        }

        $saiwParams = @{
            CheckDiskSpace = $true
            Silent         = $true
        }
        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
        }
        Show-ADTInstallationWelcome @saiwParams
        Show-ADTInstallationProgress
    }

    InstallScriptBlock       = {
        Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] Before installer launch: PID=[$PID], User=[$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)], SessionId=[$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)]." -Severity Info
        $notepadProcesses = @(Get-Process -Name 'notepad++' -ErrorAction SilentlyContinue)
        if ($notepadProcesses.Count -eq 0)
        {
            Write-ADTLogEntry -Message '[TEMP-VERIFY-NPP-SESSION] Before installer launch notepad++ process: none found.' -Severity Warning
            $legacyNotepadPath = Join-Path ${env:ProgramFiles(x86)} 'Notepad++\notepad++.exe'
            if (Test-Path -LiteralPath $legacyNotepadPath -PathType Leaf)
            {
                try
                {
                    Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] Before installer launch starting notepad++ from [$legacyNotepadPath] because no process was found." -Severity Info
                    $startedNotepadProcess = Start-Process -FilePath $legacyNotepadPath -PassThru
                    Start-Sleep -Seconds 3
                    $notepadProcesses = @(Get-Process -Name 'notepad++' -ErrorAction SilentlyContinue)
                    if ($notepadProcesses.Count -eq 0)
                    {
                        Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] Before installer launch notepad++ start verification failed: process was still not found. StartedProcessId=[$($startedNotepadProcess.Id)]." -Severity Warning
                    }
                    else
                    {
                        foreach ($notepadProcess in $notepadProcesses)
                        {
                            Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] Before installer launch notepad++ start verification: PID=[$($notepadProcess.Id)], SessionId=[$($notepadProcess.SessionId)], Path=[$($notepadProcess.Path)]." -Severity Info
                        }
                    }
                }
                catch
                {
                    Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] Before installer launch failed to start notepad++ from [$legacyNotepadPath]. $($_.Exception.Message)" -Severity Warning
                }
            }
            else
            {
                Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] Before installer launch cannot start notepad++ because path was not found: [$legacyNotepadPath]." -Severity Warning
            }
        }
        else
        {
            foreach ($notepadProcess in $notepadProcesses)
            {
                Write-ADTLogEntry -Message "[TEMP-VERIFY-NPP-SESSION] Before installer launch notepad++ process: PID=[$($notepadProcess.Id)], SessionId=[$($notepadProcess.SessionId)], Path=[$($notepadProcess.Path)]." -Severity Info
            }
        }
        Start-ADTProcess -FilePath "npp.$($adtSession.AppVersion).Installer.exe" -ArgumentList '/S'
    }

    PostInstallScriptBlock   = {
        Close-ADTInstallationProgress
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
        Stop-AdditionalTestRecording
    }

    PreUninstallScriptBlock  = {
        Start-AdditionalTestRecording

        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 10
        }
        Show-ADTInstallationProgress
    }

    UninstallScriptBlock     = {
        Uninstall-ADTApplication -Name 'Notepad++ (64-bit x64)' -NameMatch 'Exact' -ArgumentList '/S'
    }

    PostUninstallScriptBlock = {
        Close-ADTInstallationProgress
        Stop-AdditionalTestRecording
    }

    PreRepairScriptBlock     = {
        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 10
        }
        Show-ADTInstallationProgress
    }

    RepairScriptBlock        = {
        Uninstall-ADTApplication -Name 'Notepad++ (64-bit x64)' -NameMatch 'Exact' -ArgumentList '/S'
        Start-ADTProcess -FilePath "npp.$($adtSession.AppVersion).Installer.exe" -ArgumentList '/S'
    }

    PostRepairScriptBlock    = {
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait
    }
}
