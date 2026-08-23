[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    'NewADTTemplateParameters',
    Justification = 'This hashtable is consumed by external test harness code after the script is loaded.'
)]
$NewADTTemplateParameters = @{
    SessionProperties        = @{
        AppVendor                   = 'Igor Pavlov'
        AppName                     = '7-Zip ForceClose'
        AppVersion                  = '24.09'
        AppArch                     = 'x64'
        AppLang                     = 'EN'
        AppRevision                 = '01'
        AppSuccessExitCodes         = @(0, 3010)
        AppRebootExitCodes          = @(1641, 3010)
        AppProcessesToClose         = @(@{ Name = '7zFM'; Description = '7-Zip File Manager' })
        RequireAdmin                = $true
        AppScriptVersion            = '1.0.0'
        AppScriptDate               = '2026-08-20'
        AppScriptAuthor             = 'PSAppDeployToolkit'
        InstallName                 = ''
        InstallTitle                = ''
        DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
        DeployAppScriptParameters   = $PSBoundParameters
        DeployAppScriptVersion      = '4.2.0'
    }
    Destination              = 'C:\PSADT\SevenZipForceClose'
    Files                    = 'C:\Tools\Intune\7z2409-x64.msi'
    PreInstallScriptBlock    = {
        Start-AdditionalTestRecording

        $saiwParams = @{
            AllowDefer                   = $true
            DeferTimes                   = 2
            ForceCloseProcessesCountdown = 10
            CheckDiskSpace               = $true
        }
        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
        }
        Show-ADTInstallationWelcome @saiwParams
        Show-ADTInstallationProgress
    }

    InstallScriptBlock       = {
        Start-ADTMsiProcess -Action Install -FilePath '7z2409-x64.msi'
    }

    PostInstallScriptBlock   = {
        Close-ADTInstallationProgress
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
        Stop-AdditionalTestRecording
    }

    PreUninstallScriptBlock  = {
        Start-AdditionalTestRecording

        $saiwParams = @{
            ForceCloseProcessesCountdown = 10
        }
        if ($adtSession.AppProcessesToClose.Count -gt 0)
        {
            $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
        }
        Show-ADTInstallationWelcome @saiwParams
        Show-ADTInstallationProgress
    }

    UninstallScriptBlock     = {
        Start-ADTMsiProcess -Action Uninstall -FilePath '7z2409-x64.msi'
    }

    PostUninstallScriptBlock = {
        Close-ADTInstallationProgress
        Stop-AdditionalTestRecording
    }

    PreRepairScriptBlock     = {
        Show-ADTInstallationProgress
    }

    RepairScriptBlock        = {
        Start-ADTMsiProcess -Action Repair -FilePath '7z2409-x64.msi' -RepairFromSource
    }

    PostRepairScriptBlock    = {
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait
    }
}
