$supportFilesPath = (Join-Path $PSScriptRoot '..\..\..\..\examples\VLC\SupportFiles\vlc')
if (-not (Test-Path -Path $supportFilesPath -PathType Container))
{
    throw "Support files directory does not exist. path: $supportFilesPath"
}

$NewADTTemplateParameters = @{
    SessionProperties        = @{
        AppVendor                   = 'VideoLAN'
        AppName                     = 'VLC media player'
        AppVersion                  = '3.0.23'
        AppArch                     = 'x64'
        AppLang                     = 'EN'
        AppRevision                 = '01'
        AppSuccessExitCodes         = @(0)
        AppRebootExitCodes          = @(1641, 3010)
        AppProcessesToClose         = @(@{ Name = 'vlc'; Description = 'VLC media player' })
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
    Destination              = 'C:\PSADT\VLC'
    Files                    = 'C:\Tools\Intune\VLC\vlc-3.0.23-win64.exe'
    SupportFiles             = $supportFilesPath

    PreInstallScriptBlock    = {
        Start-AdditionalTestRecording

        $saiwParams = @{
            AllowDeferCloseProcesses = $true
            DeferTimes               = 3
            PersistPrompt            = $true
        }
        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
        }
        Show-ADTInstallationWelcome @saiwParams
        Show-ADTInstallationProgress
    }

    InstallScriptBlock       = {
        Start-ADTProcess -FilePath "vlc-$($adtSession.AppVersion)-win64.exe" -ArgumentList '/L=1033 /S'
    }

    PostInstallScriptBlock   = {
        Stop-AdditionalTestRecording

        Remove-ADTFile -Path "$envCommonDesktop\VLC media player.lnk", "$envCommonStartMenuPrograms\VideoLAN\Release Notes.lnk", "$envCommonStartMenuPrograms\VideoLAN\Documentation.lnk", "$envCommonStartMenuPrograms\VideoLAN\VideoLAN Website.lnk"
        Copy-ADTFileToUserProfiles -Path "$($adtSession.DirSupportFiles)\vlc" -Destination 'AppData\Roaming' -Recurse
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
    }

    PreUninstallScriptBlock  = {
        Start-AdditionalTestRecording

        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
        }
        Show-ADTInstallationProgress
    }

    UninstallScriptBlock     = {
        Uninstall-ADTApplication -Name 'VLC media player' -NameMatch 'Exact' -ArgumentList '/S'
    }

    PostUninstallScriptBlock = {
        Stop-AdditionalTestRecording
    }

    PreRepairScriptBlock     = {
        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
        }
        Show-ADTInstallationProgress
    }

    RepairScriptBlock        = {
        Uninstall-ADTApplication -Name 'VLC media player' -NameMatch 'Exact' -ArgumentList '/S'
        Start-ADTProcess -FilePath "vlc-$($adtSession.AppVersion)-win64.exe" -ArgumentList '/L=1033 /S'
    }

    PostRepairScriptBlock    = {
        Remove-ADTFile -Path "$envCommonDesktop\VLC media player.lnk", "$envCommonStartMenuPrograms\VideoLAN\Release Notes.lnk", "$envCommonStartMenuPrograms\VideoLAN\Documentation.lnk", "$envCommonStartMenuPrograms\VideoLAN\VideoLAN Website.lnk"
        Copy-ADTFileToUserProfiles -Path "$($adtSession.DirSupportFiles)\vlc" -Destination 'AppData\Roaming' -Recurse
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
    }
}
