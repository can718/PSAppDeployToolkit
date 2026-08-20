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
        Start-ADTProcess -FilePath '7z2409-x64.msi' -ArgumentList '/qn /norestart'
        $markerPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PSADT-7ZipForceClose'
        New-Item -Path $markerPath -Force | Out-Null
        New-ItemProperty -Path $markerPath -Name 'DisplayName' -Value 'PSADT 7-Zip ForceClose' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $markerPath -Name 'DisplayVersion' -Value $adtSession.AppVersion -PropertyType String -Force | Out-Null
    }

    PostInstallScriptBlock   = {
        Close-ADTInstallationProgress
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
        Stop-AdditionalTestRecording
    }

    PreUninstallScriptBlock  = {
        Start-AdditionalTestRecording
        Show-ADTInstallationProgress
    }

    UninstallScriptBlock     = {
        Remove-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PSADT-7ZipForceClose' -Recurse -Force -ErrorAction SilentlyContinue
    }

    PostUninstallScriptBlock = {
        Close-ADTInstallationProgress
        Stop-AdditionalTestRecording
    }

    PreRepairScriptBlock     = {
        Show-ADTInstallationProgress
    }

    RepairScriptBlock        = {
        Start-ADTProcess -FilePath '7z2409-x64.msi' -ArgumentList '/qn /norestart'
    }

    PostRepairScriptBlock    = {
        Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait
    }
}
