[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    'NewADTTemplateParameters',
    Justification = 'This hashtable is consumed by external test harness code after the script is loaded.'
)]
$NewADTTemplateParameters = @{
    SessionProperties        = @{
        AppVendor                   = 'Martin Prikryl'
        AppName                     = 'WinSCP'
        AppVersion                  = '6.5.6'
        AppArch                     = 'x64'
        AppLang                     = 'EN'
        AppRevision                 = '01'
        AppSuccessExitCodes         = @(0)
        AppRebootExitCodes          = @(1641, 3010)
        AppProcessesToClose         = @(@{ Name = 'WinSCP'; Description = 'WinSCP' })
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
    Destination              = 'C:\PSADT\winSCP'
    Files                    = 'C:\Tools\Intune\WinSCP\WinSCP-6.5.6.msi'
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
        Start-ADTMsiProcess -Action Install -FilePath "WinSCP-$($adtSession.AppVersion).msi"
    }

    PostInstallScriptBlock   = {
        Remove-ADTFile -Path "$envCommonDesktop\WinSCP.lnk"
        Invoke-ADTAllUsersRegistryAction {
            Set-ADTRegistryKey -LiteralPath 'HKCU\Software\Martin Prikryl\WinSCP 2\Configuration\Interface' -Name 'CollectUsage' -Value 0 -Type DWord -SID $_.SID
            Set-ADTRegistryKey -LiteralPath 'HKCU\Software\Martin Prikryl\WinSCP 2\Configuration\Interface\Updates' -Name 'Period' -Value 0 -Type DWord -SID $_.SID
            Set-ADTRegistryKey -LiteralPath 'HKCU\Software\Martin Prikryl\WinSCP 2\Configuration\Interface\Updates' -Name 'BetaVersions' -Value 1 -Type DWord -SID $_.SID
            Set-ADTRegistryKey -LiteralPath 'HKCU\Software\Martin Prikryl\WinSCP 2\Configuration\Interface\Updates' -Name 'ShowOnStartup' -Value 0 -Type DWord -SID $_.SID
        }
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
        Stop-AdditionalTestRecording
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
        Start-ADTMsiProcess -Action Uninstall -FilePath "WinSCP-$($adtSession.AppVersion).msi"
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
        Start-ADTMsiProcess -Action Repair -FilePath "WinSCP-$($adtSession.AppVersion).msi" -RepairFromSource
    }

    PostRepairScriptBlock    = {
        Remove-ADTFile -Path "$envCommonDesktop\WinSCP.lnk"
        Invoke-ADTAllUsersRegistryAction -RegistrySettings {
            Set-ADTRegistryKey -LiteralPath 'HKCU\Software\Martin Prikryl\WinSCP 2\Configuration\Interface' -Name 'CollectUsage' -Value 0 -Type DWord -SID $_.SID
            Set-ADTRegistryKey -LiteralPath 'HKCU\Software\Martin Prikryl\WinSCP 2\Configuration\Interface\Updates' -Name 'Period' -Value 0 -Type DWord -SID $_.SID
            Set-ADTRegistryKey -LiteralPath 'HKCU\Software\Martin Prikryl\WinSCP 2\Configuration\Interface\Updates' -Name 'BetaVersions' -Value 1 -Type DWord -SID $_.SID
            Set-ADTRegistryKey -LiteralPath 'HKCU\Software\Martin Prikryl\WinSCP 2\Configuration\Interface\Updates' -Name 'ShowOnStartup' -Value 0 -Type DWord -SID $_.SID
        }
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
    }
}
