<#
.SYNOPSIS
    PatchMyPC Publishing Service 2.1.110.4 - PSADT v3 Deployment Script
    Auto-generated on 2026-05-20
#>
[CmdletBinding()]
Param (
    [ValidateSet('Install','Uninstall','Repair')]
    [string]$DeploymentType = 'Install',
    [ValidateSet('Interactive','Silent','NonInteractive')]
    [string]$DeployMode = 'Interactive',
    [switch]$AllowRebootPassThru = $false,
    [switch]$TerminalServerMode = $false,
    [switch]$DisableLogging = $false
)

Try {
    Try { Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop' } Catch {}

    ##*=============================================
    ##* VARIABLE DECLARATION
    ##*=============================================
    [string]$appVendor        = 'PatchMyPC'
    [string]$appName          = 'PatchMyPC Publishing Service'
    [string]$appVersion       = '2.1.110.4'
    [string]$appArch          = ''
    [string]$appLang          = 'EN'
    [string]$appRevision      = '01'
    [string]$appScriptVersion = '1.0.0'
    [string]$appScriptDate    = '05/20/2026'
    [string]$appScriptAuthor  = 'Auto-generated'

    ## Do not modify below
    [int32]$mainExitCode = 0
    If (Test-Path -LiteralPath 'variable:HostInvocation') { $InvocationInfo = $HostInvocation } Else { $InvocationInfo = $MyInvocation }
    [string]$scriptDirectory = Split-Path -Path $InvocationInfo.MyCommand.Definition -Parent

    Try {
        [string]$moduleMain = "$scriptDirectory\AppDeployToolkit\AppDeployToolkitMain.ps1"
        If (-not (Test-Path -LiteralPath $moduleMain -PathType 'Leaf')) { Throw "Module not found: [$moduleMain]" }
        If ($DisableLogging) { . $moduleMain -DisableLogging } Else { . $moduleMain }
    } Catch {
        If ($mainExitCode -eq 0) { [int32]$mainExitCode = 60008 }
        Write-Error -Message "Module failed to load: `n$($_.Exception.Message)" -ErrorAction 'Continue'
        If (Test-Path -LiteralPath 'variable:HostInvocation') { $script:ExitCode = $mainExitCode; Exit } Else { Exit $mainExitCode }
    }
    ##*=============================================

    If ($deploymentType -ine 'Uninstall' -and $deploymentType -ine 'Repair') {

        ##*=============================================
        ##* PRE-INSTALLATION
        ##*=============================================
        [string]$installPhase = 'Pre-Installation'

        Show-InstallationWelcome -AllowDefer -DeferTimes 3 -CheckDiskSpace -PersistPrompt
        Show-InstallationProgress

        ##*=============================================
        ##* INSTALLATION
        ##*=============================================
        [string]$installPhase = 'Installation'

        Execute-MSI -Action 'Install' -Path "$dirFiles\PatchMyPC-Publishing-Service-2.1.110.4 (2).msi" -Parameters '/QN REBOOT=ReallySuppress'

        ##*=============================================
        ##* POST-INSTALLATION
        ##*=============================================
        [string]$installPhase = 'Post-Installation'

    } ElseIf ($deploymentType -ieq 'Uninstall') {

        ##*=============================================
        ##* PRE-UNINSTALLATION
        ##*=============================================
        [string]$installPhase = 'Pre-Uninstallation'

        Show-InstallationWelcome -CloseAppsCountdown 60
        Show-InstallationProgress

        ##*=============================================
        ##* UNINSTALLATION
        ##*=============================================
        [string]$installPhase = 'Uninstallation'

        Execute-MSI -Action 'Uninstall' -Path ' {DB6DB066-68E6-42F6-A659-1344346B7026}'

        ##*=============================================
        ##* POST-UNINSTALLATION
        ##*=============================================
        [string]$installPhase = 'Post-Uninstallation'

    } ElseIf ($deploymentType -ieq 'Repair') {

        ##*=============================================
        ##* PRE-REPAIR
        ##*=============================================
        [string]$installPhase = 'Pre-Repair'

        Show-InstallationWelcome
        Show-InstallationProgress

        ##*=============================================
        ##* REPAIR
        ##*=============================================
        [string]$installPhase = 'Repair'

        Execute-MSI -Action 'Repair' -Path "$dirFiles\PatchMyPC-Publishing-Service-2.1.110.4 (2).msi" -Parameters '/QN REBOOT=ReallySuppress'

        ##*=============================================
        ##* POST-REPAIR
        ##*=============================================
        [string]$installPhase = 'Post-Repair'
    }

    Exit-Script -ExitCode $mainExitCode
} Catch {
    [int32]$mainExitCode = 60001
    Write-Log -Message "$(Resolve-Error)" -Severity 3 -Source 'Deploy-Application'
    Exit-Script -ExitCode $mainExitCode
}
