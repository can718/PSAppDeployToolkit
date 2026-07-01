[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    'NewADTTemplateParameters',
    Justification = 'This hashtable is consumed by external test harness code after the script is loaded.'
)]
$NewADTTemplateParameters = @{
    SessionProperties        = @{
        AppVendor                   = 'Don HO don.h@free.fr'
        AppName                     = 'Notepad++'
        AppVersion                  = '6.6.4'
        AppArch                     = 'x64'
        AppLang                     = 'EN'
        AppRevision                 = '01'
        AppSuccessExitCodes         = @(0)
        AppRebootExitCodes          = @(1641, 3010)
        AppProcessesToClose         = @(@{ Name = 'notepad++'; Description = 'Notepad++' })
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
    Files                    = 'C:\Tools\Intune\npp.6.6.4.Installer.exe'
    PreInstallScriptBlock    = {
        Start-AdditionalTestRecording

        $saiwParams = @{
            AllowDefer     = $true
            DeferTimes     = 2
            ForceCountdown = 8
            CheckDiskSpace = $true
        }
        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            #$saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
        }
        Show-ADTInstallationWelcome @saiwParams
        Show-ADTInstallationProgress
    }

    InstallScriptBlock       = {
        Start-ADTProcess -FilePath "npp.$($adtSession.AppVersion).Installer.exe" -ArgumentList '/S'
    }

    PostInstallScriptBlock   = {
        Stop-AdditionalTestRecording

        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
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
