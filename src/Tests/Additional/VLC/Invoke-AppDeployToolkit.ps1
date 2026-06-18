<#
.SYNOPSIS
This script invokes a PSAppDeployToolkit deployment.

.DESCRIPTION
The script imports the PSAppDeployToolkit module and executes the specified install/uninstall/repair scriptblocks.

.PARAMETER DeploymentType
The type of deployment to perform, Install, Uninstall, or Repair. Default is Install.

.PARAMETER DeployMode
Specifies whether the installation should be run in Interactive (shows dialogs), Silent (no dialogs), NonInteractive (dialogs without prompts) mode, or Auto (shows dialogs if a user is logged on, device is not in the OOBE, and there's no running apps to close).

Silent mode is automatically set if it is detected that the process is not user interactive, no users are logged on, the device is in Autopilot mode, or there's specified processes to close that are currently running.

.PARAMETER SuppressRebootPassThru
Prevents the toolkit from exiting with a defined reboot exit code (e.g. 3010), returning 0 instead.

.PARAMETER TerminalServerMode
Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging
Disables logging to file for the script.

.EXAMPLE
Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseDeclaredVarsMoreThanAssignments", "", Justification = "Ignore unused variables in this script")]
[CmdletBinding()]
param
(
    # Default is 'Install'.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    # Default is 'Auto'. Don't hard-code this unless required.
    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)

## MARK: Variables
$adtSession = @{
    AppVendor = 'VideoLAN'
    AppName = 'VLC media player'
    AppVersion = '3.0.23'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @(@{ Name = 'vlc'; Description = 'VLC media player' })
    RequireAdmin = $true

    AppScriptVersion = '1.0.0'
    AppScriptDate = '2026-04-01'
    AppScriptAuthor = 'PSAppDeployToolkit'

    # Install Titles (Only set here to override defaults set by the toolkit).
    InstallName = ''
    InstallTitle = ''

    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name
    DeployAppScriptParameters = $PSBoundParameters
    DeployAppScriptVersion = '4.2.0'
}

## MARK: Pre-Install
$PreInstall = {
    $saiwParams = @{
        AllowDeferCloseProcesses = $true
        DeferTimes = 3
        PersistPrompt = $true
    }
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        $saiwParams.Add('CloseProcesses', $adtSession.AppProcessesToClose)
    }
    Show-ADTInstallationWelcome @saiwParams
    Show-ADTInstallationProgress
}

## MARK: Install
$Install = {
    Start-ADTProcess -FilePath "vlc-$($adtSession.AppVersion)-win64.exe" -ArgumentList '/L=1033 /S'
}

## MARK: Post-Install
$PostInstall = {
    Remove-ADTFile -Path "$envCommonDesktop\VLC media player.lnk", "$envCommonStartMenuPrograms\VideoLAN\Release Notes.lnk", "$envCommonStartMenuPrograms\VideoLAN\Documentation.lnk", "$envCommonStartMenuPrograms\VideoLAN\VideoLAN Website.lnk"
    Copy-ADTFileToUserProfiles -Path "$($adtSession.DirSupportFiles)\vlc" -Destination 'AppData\Roaming' -Recurse
    Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait
}

## MARK: Pre-Uninstall
$PreUninstall = {
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress
}

## MARK: Uninstall
$Uninstall = {
    Uninstall-ADTApplication -Name 'VLC media player' -NameMatch 'Exact' -ArgumentList '/S'
}

## MARK: Post-Uninstall
$PostUninstall = {
}

## MARK: Pre-Repair
$PreRepair = {
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60
    }
    Show-ADTInstallationProgress
}

## MARK: Repair
$Repair = {
    Uninstall-ADTApplication -Name 'VLC media player' -NameMatch 'Exact' -ArgumentList '/S'
    Start-ADTProcess -FilePath "vlc-$($adtSession.AppVersion)-win64.exe" -ArgumentList '/L=1033 /S'
}

## MARK: Post-Repair
$PostRepair = {
    Remove-ADTFile -Path "$envCommonDesktop\VLC media player.lnk", "$envCommonStartMenuPrograms\VideoLAN\Release Notes.lnk", "$envCommonStartMenuPrograms\VideoLAN\Documentation.lnk", "$envCommonStartMenuPrograms\VideoLAN\VideoLAN Website.lnk"
    Copy-ADTFileToUserProfiles -Path "$($adtSession.DirSupportFiles)\vlc" -Destination 'AppData\Roaming' -Recurse
    Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait
}

## MARK: Initialization
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

$recordingStarted = $false
$recordingOutputFile = $null
$helperLoaded = $false
try
{
    if (Test-Path -LiteralPath "$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -FullyQualifiedName @{ ModuleName = [System.Management.Automation.WildcardPattern]::Escape("$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1"); Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.2.0' } -Force
    }
    else
    {
        Import-Module -FullyQualifiedName @{ ModuleName = 'PSAppDeployToolkit'; Guid = '8c3c366b-8606-4576-9f2d-4051144f7ca2'; ModuleVersion = '4.2.0' } -Force
    }
    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru

    try
    {
        $helperScriptPath = "C:\PSADTScripts\TerraForge-AgentHelper.ps1"
        if ([System.String]::IsNullOrWhiteSpace($helperScriptPath) -or -not (Test-Path -LiteralPath $helperScriptPath -PathType Leaf))
        {
            $helperScriptPath = Join-Path $PSScriptRoot '..\..\..\..\.github\scripts\TerraForge-AgentHelper.ps1'
        }
        if (Test-Path -LiteralPath $helperScriptPath -PathType Leaf)
        {
            . $helperScriptPath
            $helperLoaded = $true
        }
        else
        {
            Write-ADTLogEntry -Message "TerraForge-AgentHelper.ps1 not found at path: $helperScriptPath. Skipping recording start." -Severity Warning
        }
    }
    catch
    {
        Write-ADTLogEntry -Message "Failed to load TerraForge-AgentHelper.ps1. Skipping recording integration. $($_.Exception.Message)" -Severity Warning
    }

    try
    {
        if ($helperLoaded -and (Get-Command -Name Start-TerraForgeRecording -ErrorAction SilentlyContinue))
        {
            Write-ADTLogEntry -Message "Starting recording for [$($adtSession.AppName)] deployment type [$($adtSession.DeploymentType)]." -Severity Info
            $recordingContext = Start-TerraForgeRecording -AppName $adtSession.AppName -DeploymentType $adtSession.DeploymentType
            $recordingStarted = $recordingContext.Started
            $recordingOutputFile = $recordingContext.OutputFile

            if ($recordingStarted)
            {
                Write-ADTLogEntry -Message "Recording started successfully. Output file: [$recordingOutputFile]." -Severity Info
            }
            else
            {
                Write-ADTLogEntry -Message "Recording start completed without starting an active recording." -Severity Warning
            }
        }
    }
    catch
    {
        Write-ADTLogEntry -Message "Failed to start recording. Deployment will continue. $($_.Exception.Message)" -Severity Warning
    }
}
catch
{
    $Host.UI.WriteErrorLine((Out-String -InputObject $_ -Width ([System.Int16]::MaxValue)))
    exit 60008
}

## MARK: Invocation
try
{
    # Import any PSAppDeployToolkit.* extensions
    Get-ChildItem -LiteralPath $PSScriptRoot -Directory | & {
        process
        {
            if ($_.Name -match 'PSAppDeployToolkit\..+$')
            {
                Get-ChildItem -LiteralPath $_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name ([System.Management.Automation.WildcardPattern]::Escape("$($_.FullName)\$($_.BaseName).psd1")) -Force
            }
        }
    }
    foreach ($prefix in 'Pre-', '', 'Post-')
    {
        $installPhase = "$prefix$($adtSession.DeploymentType)"
        $scriptBlock = Get-Variable -Name $installPhase.Replace('-', '') -ValueOnly -ErrorAction Ignore
        if (![System.String]::IsNullOrWhiteSpace($scriptBlock))
        {
            $adtSession.InstallPhase = $installPhase
            . $scriptBlock
        }
    }
    Close-ADTSession
}
catch
{
    $mainErrorMessage = "An unhandled error within [$($MyInvocation.MyCommand.Name)] has occurred.`n$(Resolve-ADTErrorRecord -ErrorRecord $_)"
    Write-ADTLogEntry -Message $mainErrorMessage -Severity Error

    ## Error details hidden from the user by default. Show a simple dialog with full stack trace:
    # Show-ADTDialogBox -Text $mainErrorMessage -Icon Stop -NoWait

    ## Or, a themed dialog with basic error message:
    # Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) failed at line $($_.InvocationInfo.ScriptLineNumber), char $($_.InvocationInfo.OffsetInLine):`n$($_.InvocationInfo.Line.Trim())`n`nMessage:`n$($_.Exception.Message)" -ButtonRightText OK -NoWait

    Close-ADTSession -ExitCode 60001
}
finally
{
    # Best-effort recording stop. Never block deployment completion if stop fails.
    if ($recordingStarted)
    {
        if ($helperLoaded -and (Get-Command -Name Stop-TerraForgeRecording -ErrorAction SilentlyContinue))
        {
            Write-ADTLogEntry -Message "Stopping recording for [$($adtSession.AppName)] deployment type [$($adtSession.DeploymentType)]." -Severity Info
            Stop-TerraForgeRecording -RecordingStarted:$recordingStarted -RecordingOutputFile $recordingOutputFile -UploadToStorageAccount
            Write-ADTLogEntry -Message "Recording stop request completed for output file [$recordingOutputFile]." -Severity Info
        }
    }
}
