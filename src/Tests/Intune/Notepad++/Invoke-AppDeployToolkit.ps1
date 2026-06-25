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
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]

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
    AppVendor = 'Don HO don.h@free.fr'
    AppName = 'Notepad++'
    AppVersion = '6.6.4'
    AppArch = 'x64'
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppProcessesToClose = @(@{ Name = 'notepad++'; Description = 'Notepad++' })
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
        AllowDefer = $true
        DeferTimes = 2
        # PersistPrompt = $true
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

## MARK: Install
$Install = {
    Start-ADTProcess -FilePath "npp.$($adtSession.AppVersion).Installer.exe" -ArgumentList '/S'
}

## MARK: Post-Install
$PostInstall = {
    Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait -Timeout 5
}

## MARK: Pre-Uninstall
$PreUninstall = {
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 10
    }
    Show-ADTInstallationProgress
}

## MARK: Uninstall
$Uninstall = {
    Uninstall-ADTApplication -Name 'Notepad++ (64-bit x64)' -NameMatch 'Exact' -ArgumentList '/S'
}

## MARK: Post-Uninstall
$PostUninstall = {
}

## MARK: Pre-Repair
$PreRepair = {
    if ($adtSession.AppProcessesToClose.Count -gt 0)
    {
        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 10
    }
    Show-ADTInstallationProgress
}

## MARK: Repair
$Repair = {
    Uninstall-ADTApplication -Name 'Notepad++ (64-bit x64)' -NameMatch 'Exact' -ArgumentList '/S'
    Start-ADTProcess -FilePath "npp.$($adtSession.AppVersion).Installer.x64.exe"
}

## MARK: Post-Repair
$PostRepair = {
    #Remove-ADTFile -Path "$envCommonDesktop\VLC media player.lnk", "$envCommonStartMenuPrograms\VideoLAN\Release Notes.lnk", "$envCommonStartMenuPrograms\VideoLAN\Documentation.lnk", "$envCommonStartMenuPrograms\VideoLAN\VideoLAN Website.lnk"
    # Copy-ADTFileToUserProfiles -Path "$($adtSession.DirSupportFiles)\vlc" -Destination 'AppData\Roaming' -Recurse
    Show-ADTInstallationPrompt -Message "$($adtSession.DeploymentType) complete." -ButtonRightText 'OK' -NoWait
}

## MARK: Initialization
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

$recordingStarted = $false
$recordingStopAttempted = $false
$recordingOutputFile = $null
$helperLoaded = $false

function Start-AdditionalTestRecording
{
    Write-ADTLogEntry -Message 'Start-AdditionalTestRecording callback invoked.' -Severity Info

    if ($script:recordingStarted)
    {
        Write-ADTLogEntry -Message 'Recording start skipped because a recording is already active.' -Severity Info
        return
    }

    try
    {
        if (-not $script:helperLoaded)
        {
            Write-ADTLogEntry -Message 'Recording start skipped because TerraForge helper was not loaded.' -Severity Warning
            return
        }

        if (-not (Get-Command -Name Start-TerraForgeRecording -ErrorAction SilentlyContinue))
        {
            Write-ADTLogEntry -Message 'Recording start skipped because Start-TerraForgeRecording is unavailable.' -Severity Info
            return
        }

        $currentSession = Get-ADTSession
        Write-ADTLogEntry -Message "Starting recording for [$($currentSession.AppName)] deployment type [$($currentSession.DeploymentType)]." -Severity Info
        $recordingContext = Start-TerraForgeRecording -AppName $currentSession.AppName -DeploymentType $currentSession.DeploymentType
        $script:recordingStarted = $recordingContext.Started
        $script:recordingOutputFile = $recordingContext.OutputFile

        if ($script:recordingStarted)
        {
            Write-ADTLogEntry -Message "Recording started successfully. Output file: [$($script:recordingOutputFile)]." -Severity Info
        }
        else
        {
            $recordingReason = if ([System.String]::IsNullOrWhiteSpace($recordingContext.Reason)) { 'No additional detail was returned by the TerraForge helper.' } else { $recordingContext.Reason }
            Write-ADTLogEntry -Message "Recording start completed without starting an active recording. $recordingReason" -Severity Info
        }
    }
    catch
    {
        Write-ADTLogEntry -Message "Failed to start recording. Deployment will continue. $($_.Exception.Message)" -Severity Info
    }
}

function Stop-AdditionalTestRecording
{
    Write-ADTLogEntry -Message 'Stop-AdditionalTestRecording callback invoked.' -Severity Info

    if ($script:recordingStopAttempted)
    {
        Write-ADTLogEntry -Message 'Recording stop skipped because a stop was already attempted.' -Severity Info
        return
    }

    if (!$script:recordingStarted)
    {
        Write-ADTLogEntry -Message 'Recording stop skipped because no recording was started.' -Severity Warning
        return
    }

    $script:recordingStopAttempted = $true

    if (-not $script:helperLoaded)
    {
        Write-ADTLogEntry -Message 'Recording stop skipped because TerraForge helper was not loaded.' -Severity Warning
        return
    }

    if (-not (Get-Command -Name Stop-TerraForgeRecording -ErrorAction SilentlyContinue))
    {
        Write-ADTLogEntry -Message 'Recording stop skipped because Stop-TerraForgeRecording is unavailable.' -Severity Warning
        return
    }

    Start-Sleep -Seconds 3
    $uploadEnvironmentStatus = @(
        "TERRAFORGE_API_BASE_URL=$(-not [System.String]::IsNullOrWhiteSpace($env:TERRAFORGE_API_BASE_URL))"
        "TEST_RUN_ID=$(-not [System.String]::IsNullOrWhiteSpace($env:TEST_RUN_ID))"
        "INFRA_MI_CLIENT_ID=$(-not [System.String]::IsNullOrWhiteSpace($env:INFRA_MI_CLIENT_ID))"
        "INFRA_KEYVAULT=$(-not [System.String]::IsNullOrWhiteSpace($env:INFRA_KEYVAULT))"
        "TERRAFORGE_API_KEY_SECRET=$(-not [System.String]::IsNullOrWhiteSpace($env:TERRAFORGE_API_KEY_SECRET))"
    ) -join ', '
    Write-ADTLogEntry -Message "TerraForge upload environment status: $uploadEnvironmentStatus" -Severity Info
    Write-ADTLogEntry -Message "Stopping recording for [$($script:adtSession.AppName)] deployment type [$($script:adtSession.DeploymentType)]." -Severity Info
    $recordingResult = Stop-TerraForgeRecording -RecordingStarted:$script:recordingStarted -RecordingOutputFile $script:recordingOutputFile
    if ($recordingResult.Error)
    {
        Write-ADTLogEntry -Message "Recording stop/upload completed with warning for output file [$($script:recordingOutputFile)]: $($recordingResult.Error)" -Severity Warning
    }
    elseif ($recordingResult.UploadRequested -and $recordingResult.UploadSucceeded)
    {
        Write-ADTLogEntry -Message "Recording stopped and uploaded successfully for output file [$($script:recordingOutputFile)]." -Severity Info
    }
    elseif (-not $recordingResult.UploadRequested)
    {
        Append-RegistryValue -Name 'RecordingUploadNotRequested' -Value $script:recordingOutputFile
        Write-ADTLogEntry -Message "Set registry value for output file [$($script:recordingOutputFile)] successfully." -Severity info
    }
    else
    {
        Write-ADTLogEntry -Message "Recording stop request completed for output file [$($script:recordingOutputFile)]." -Severity Info
    }
}

function Register-AdditionalTestRecordingCallbacks
{
    Add-ADTModuleCallback -Hookpoint PostOpen -Callback (Get-Command -Name Start-AdditionalTestRecording)
    Add-ADTModuleCallback -Hookpoint OnFinish -Callback (Get-Command -Name Stop-AdditionalTestRecording)
}

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

    $iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation $MyInvocation
    $adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable $adtSession
    Register-AdditionalTestRecordingCallbacks
    $adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
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
