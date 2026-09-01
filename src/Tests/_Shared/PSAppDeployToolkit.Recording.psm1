$script:recordingStarted = $false
$script:recordingStopAttempted = $false
$script:recordingOutputFile = $null
$script:helperLoaded = $false
$script:terraForgeHelperModule = $null

function script:Register-AdditionalTestRecordingStopCallbacks
{
    $stopCallback = Get-Command -Name Stop-AdditionalTestRecording
    Add-ADTModuleCallback -Hookpoint OnDefer -Callback $stopCallback
    Add-ADTModuleCallback -Hookpoint PreClose -Callback $stopCallback
    Add-ADTModuleCallback -Hookpoint OnFinish -Callback $stopCallback
}

<#
.SYNOPSIS
Starts additional test recording when the TerraForge helper is available.

.DESCRIPTION
Loads the TerraForge helper module when needed and starts recording for the
current ADT session. The function safely skips start operations when recording
is already active or when prerequisites are not available.
#>
function Start-AdditionalTestRecording
{
    #Import-AdditionalTestRecordingHelper firstly to ensure the helper is loaded before attempting to start recording.
    if (-not $script:helperLoaded)
    {
        Import-AdditionalTestRecordingHelper

        if (-not $script:helperLoaded)
        {
            Write-ADTLogEntry -Message 'Recording start skipped because TerraForge helper could not be loaded.' -Severity Warning
            return
        }

        #sleep for a few seconds to allow the helper to load and initialize before attempting to start recording.
        Start-Sleep -Seconds 10
        Write-ADTLogEntry -Message 'TerraForge helper loaded successfully.' -Severity Info
    }
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

        if (-not $script:terraForgeHelperModule -or -not (Get-Command -Name Start-TerraForgeRecording -Module $script:terraForgeHelperModule -CommandType Function -ErrorAction SilentlyContinue))
        {
            Write-ADTLogEntry -Message 'Recording start skipped because Start-TerraForgeRecording is unavailable.' -Severity Info
            return
        }

        $currentSession = Get-ADTSession
        Write-ADTLogEntry -Message "Starting recording for [$($currentSession.AppName)] deployment type [$($currentSession.DeploymentType)]." -Severity Info
        $recordingContext = & $script:terraForgeHelperModule {
            param
            (
                [string]$AppName,
                [string]$DeploymentType
            )

            Start-TerraForgeRecording -AppName $AppName -DeploymentType $DeploymentType
        } $currentSession.AppName $currentSession.DeploymentType
        $script:recordingStarted = $recordingContext.Started
        $script:recordingOutputFile = $recordingContext.OutputFile

        if ($script:recordingStarted)
        {
            Register-AdditionalTestRecordingStopCallbacks
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

<#
.SYNOPSIS
Starts additional test recording for PSADT v3 execution flows.

.DESCRIPTION
Uses explicit v3-compatible application and deployment metadata instead of
relying on a v4 deployment session. When values are not passed in, the
function falls back to script-scoped v3 variables when available.
#>
function Start-AdditionalTestRecordingV3
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$AppName,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$DeploymentType
    )

    if (-not $script:helperLoaded)
    {
        Import-AdditionalTestRecordingHelper

        if (-not $script:helperLoaded)
        {
            Write-ADTLogEntry -Message 'V3 recording start skipped because TerraForge helper could not be loaded.' -Severity Warning
            return
        }

        Start-Sleep -Seconds 10
        Write-ADTLogEntry -Message 'TerraForge helper loaded successfully for V3 recording.' -Severity Info
    }
    Write-ADTLogEntry -Message 'Start-AdditionalTestRecordingV3 callback invoked.' -Severity Info

    if ($script:recordingStarted)
    {
        Write-ADTLogEntry -Message 'V3 recording start skipped because a recording is already active.' -Severity Info
        return
    }

    try
    {
        if (-not $script:helperLoaded)
        {
            Write-ADTLogEntry -Message 'V3 recording start skipped because TerraForge helper was not loaded.' -Severity Warning
            return
        }

        if (-not $script:terraForgeHelperModule -or -not (Get-Command -Name Start-TerraForgeRecording -Module $script:terraForgeHelperModule -CommandType Function -ErrorAction SilentlyContinue))
        {
            Write-ADTLogEntry -Message 'V3 recording start skipped because Start-TerraForgeRecording is unavailable.' -Severity Info
            return
        }

        if ([System.String]::IsNullOrWhiteSpace($AppName) -and (Get-Variable -Name appName -Scope Script -ErrorAction SilentlyContinue))
        {
            $AppName = $script:appName
        }

        if ([System.String]::IsNullOrWhiteSpace($DeploymentType) -and (Get-Variable -Name DeploymentType -Scope Script -ErrorAction SilentlyContinue))
        {
            $DeploymentType = $script:DeploymentType
        }

        if ([System.String]::IsNullOrWhiteSpace($DeploymentType) -and (Get-Variable -Name deploymentType -Scope Script -ErrorAction SilentlyContinue))
        {
            $DeploymentType = $script:deploymentType
        }

        if ([System.String]::IsNullOrWhiteSpace($AppName))
        {
            Write-ADTLogEntry -Message 'V3 recording start skipped because AppName could not be resolved.' -Severity Warning
            return
        }

        if ([System.String]::IsNullOrWhiteSpace($DeploymentType))
        {
            Write-ADTLogEntry -Message 'V3 recording start skipped because DeploymentType could not be resolved.' -Severity Warning
            return
        }

        Write-ADTLogEntry -Message "Starting V3 recording for [$AppName] deployment type [$DeploymentType]." -Severity Info
        $recordingContext = & $script:terraForgeHelperModule {
            param
            (
                [string]$ResolvedAppName,
                [string]$ResolvedDeploymentType
            )

            Start-TerraForgeRecording -AppName $ResolvedAppName -DeploymentType $ResolvedDeploymentType
        } $AppName $DeploymentType
        $script:recordingStarted = $recordingContext.Started
        $script:recordingOutputFile = $recordingContext.OutputFile

        if ($script:recordingStarted)
        {
            Write-ADTLogEntry -Message "V3 recording started successfully. Output file: [$($script:recordingOutputFile)]." -Severity Info
        }
        else
        {
            $recordingReason = if ([System.String]::IsNullOrWhiteSpace($recordingContext.Reason)) { 'No additional detail was returned by the TerraForge helper.' } else { $recordingContext.Reason }
            Write-ADTLogEntry -Message "V3 recording start completed without starting an active recording. $recordingReason" -Severity Info
        }
    }
    catch
    {
        Write-ADTLogEntry -Message "Failed to start V3 recording. Deployment will continue. $($_.Exception.Message)" -Severity Info
    }
}

<#
.SYNOPSIS
Stops the additional test recording and uploads artifacts when available.

.DESCRIPTION
Finalizes the active TerraForge recording for the current test run. The function is
safe to invoke multiple times and logs why stop/upload is skipped when prerequisites
are not met.
#>
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

    if (-not $script:terraForgeHelperModule -or -not (Get-Command -Name Stop-TerraForgeRecording -Module $script:terraForgeHelperModule -CommandType Function -ErrorAction SilentlyContinue))
    {
        Write-ADTLogEntry -Message 'Recording stop skipped because Stop-TerraForgeRecording is unavailable.' -Severity Warning
        return
    }

    $uploadEnvironmentStatus = @(
        "TERRAFORGE_API_BASE_URL=$(-not [System.String]::IsNullOrWhiteSpace($env:TERRAFORGE_API_BASE_URL))"
        "TEST_RUN_ID=$(-not [System.String]::IsNullOrWhiteSpace($env:TEST_RUN_ID))"
        "INFRA_MI_CLIENT_ID=$(-not [System.String]::IsNullOrWhiteSpace($env:INFRA_MI_CLIENT_ID))"
        "INFRA_KEYVAULT=$(-not [System.String]::IsNullOrWhiteSpace($env:INFRA_KEYVAULT))"
        "TERRAFORGE_API_KEY_SECRET=$(-not [System.String]::IsNullOrWhiteSpace($env:TERRAFORGE_API_KEY_SECRET))"
    ) -join ', '
    Write-ADTLogEntry -Message "TerraForge upload environment status: $uploadEnvironmentStatus" -Severity Info
    Write-ADTLogEntry -Message "Stopping recording for [$($script:adtSession.AppName)] deployment type [$($script:adtSession.DeploymentType)]." -Severity Info
    $recordingResult = & $script:terraForgeHelperModule {
        param
        (
            [bool]$RecordingStarted,
            [string]$RecordingOutputFile
        )
        #sleep for a few seconds to allow the helper to finalize any pending operations before attempting to stop recording.
        Start-Sleep -Seconds 8

        Stop-TerraForgeRecording -RecordingStarted:$RecordingStarted -RecordingOutputFile $RecordingOutputFile
    } $script:recordingStarted $script:recordingOutputFile
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
        Write-ADTLogEntry -Message "Set registry value for output file [$($script:recordingOutputFile)] successfully." -Severity Info
    }
    else
    {
        Write-ADTLogEntry -Message "Recording stop request completed for output file [$($script:recordingOutputFile)]." -Severity Info
    }
}

<#
.SYNOPSIS
Stops the additional test recording for PSADT v3 execution flows.

.DESCRIPTION
Finalizes the active TerraForge recording for a v3 test run without relying on
v4 deployment session state. Application and deployment metadata can be passed
explicitly or resolved from script-scoped v3 variables when available.
#>
function Stop-AdditionalTestRecordingV3
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$AppName,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$DeploymentType
    )

    Write-ADTLogEntry -Message 'Stop-AdditionalTestRecordingV3 callback invoked.' -Severity Info

    if ($script:recordingStopAttempted)
    {
        Write-ADTLogEntry -Message 'V3 recording stop skipped because a stop was already attempted.' -Severity Info
        return
    }

    if (!$script:recordingStarted)
    {
        Write-ADTLogEntry -Message 'V3 recording stop skipped because no recording was started.' -Severity Warning
        return
    }

    $script:recordingStopAttempted = $true

    if (-not $script:helperLoaded)
    {
        Write-ADTLogEntry -Message 'V3 recording stop skipped because TerraForge helper was not loaded.' -Severity Warning
        return
    }

    if (-not $script:terraForgeHelperModule -or -not (Get-Command -Name Stop-TerraForgeRecording -Module $script:terraForgeHelperModule -CommandType Function -ErrorAction SilentlyContinue))
    {
        Write-ADTLogEntry -Message 'V3 recording stop skipped because Stop-TerraForgeRecording is unavailable.' -Severity Warning
        return
    }

    if ([System.String]::IsNullOrWhiteSpace($AppName) -and (Get-Variable -Name appName -Scope Script -ErrorAction SilentlyContinue))
    {
        $AppName = $script:appName
    }

    if ([System.String]::IsNullOrWhiteSpace($DeploymentType) -and (Get-Variable -Name DeploymentType -Scope Script -ErrorAction SilentlyContinue))
    {
        $DeploymentType = $script:DeploymentType
    }

    if ([System.String]::IsNullOrWhiteSpace($DeploymentType) -and (Get-Variable -Name deploymentType -Scope Script -ErrorAction SilentlyContinue))
    {
        $DeploymentType = $script:deploymentType
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

    if (-not [System.String]::IsNullOrWhiteSpace($AppName) -and -not [System.String]::IsNullOrWhiteSpace($DeploymentType))
    {
        Write-ADTLogEntry -Message "Stopping V3 recording for [$AppName] deployment type [$DeploymentType]." -Severity Info
    }
    else
    {
        Write-ADTLogEntry -Message 'Stopping V3 recording without resolved application metadata.' -Severity Warning
    }

    $recordingResult = & $script:terraForgeHelperModule {
        param
        (
            [bool]$RecordingStarted,
            [string]$RecordingOutputFile
        )

        Stop-TerraForgeRecording -RecordingStarted:$RecordingStarted -RecordingOutputFile $RecordingOutputFile
    } $script:recordingStarted $script:recordingOutputFile
    if ($recordingResult.Error)
    {
        Write-ADTLogEntry -Message "V3 recording stop/upload completed with warning for output file [$($script:recordingOutputFile)]: $($recordingResult.Error)" -Severity Warning
    }
    elseif ($recordingResult.UploadRequested -and $recordingResult.UploadSucceeded)
    {
        Write-ADTLogEntry -Message "V3 recording stopped and uploaded successfully for output file [$($script:recordingOutputFile)]." -Severity Info
    }
    elseif (-not $recordingResult.UploadRequested)
    {
        Append-RegistryValue -Name 'RecordingUploadNotRequested' -Value $script:recordingOutputFile
        Write-ADTLogEntry -Message "Set registry value for V3 output file [$($script:recordingOutputFile)] successfully." -Severity Info
    }
    else
    {
        Write-ADTLogEntry -Message "V3 recording stop request completed for output file [$($script:recordingOutputFile)]." -Severity Info
    }
}

<#
.SYNOPSIS
Registers recording callbacks for additional test execution.

.DESCRIPTION
Attaches the start and stop recording callbacks to ADT module hookpoints so
recording begins after startup and is finalized when execution finishes.
#>
function Register-AdditionalTestRecordingCallbacks
{
    Add-ADTModuleCallback -Hookpoint PostOpen -Callback (Get-Command -Name Start-AdditionalTestRecording)
    Register-AdditionalTestRecordingStopCallbacks
}

<#
.SYNOPSIS
Imports the TerraForge helper script used for recording operations.

.DESCRIPTION
Loads the TerraForge helper script from the expected local path into a dynamic
module and verifies required helper commands are available for subsequent
recording start and stop operations.
#>
function Import-AdditionalTestRecordingHelper
{
    try
    {
        $helperScriptPath = 'C:\PSADTScripts\TerraForge-AgentHelper.ps1'

        if (Test-Path -LiteralPath $helperScriptPath -PathType Leaf)
        {
            $helperScriptContent = Get-Content -LiteralPath $helperScriptPath -Raw
            $script:terraForgeHelperModule = New-Module -Name ('TerraForgeAgentHelper_{0}' -f [guid]::NewGuid().ToString('N')) -ScriptBlock ([scriptblock]::Create($helperScriptContent))

            $script:helperLoaded = [bool](Get-Command -Name Start-TerraForgeRecording -Module $script:terraForgeHelperModule -CommandType Function -ErrorAction SilentlyContinue)
            if ($script:helperLoaded)
            {
                Write-ADTLogEntry -Message "Loaded TerraForge helper from path: $helperScriptPath" -Severity Info
            }
            else
            {
                $script:terraForgeHelperModule = $null
                Write-ADTLogEntry -Message "TerraForge helper script loaded but Start-TerraForgeRecording was still unavailable." -Severity Warning
            }
        }
        else
        {
            $script:helperLoaded = $false
            $script:terraForgeHelperModule = $null
            Write-ADTLogEntry -Message "TerraForge-AgentHelper.ps1 not found at path: $helperScriptPath. Skipping recording start." -Severity Warning
        }
    }
    catch
    {
        $script:helperLoaded = $false
        $script:terraForgeHelperModule = $null
        Write-ADTLogEntry -Message "Failed to load TerraForge-AgentHelper.ps1. Skipping recording integration. $($_.Exception.Message)" -Severity Warning
    }
}

Export-ModuleMember -Function @(
    'Start-AdditionalTestRecording',
    'Start-AdditionalTestRecordingV3',
    'Stop-AdditionalTestRecording',
    'Stop-AdditionalTestRecordingV3',
    'Register-AdditionalTestRecordingCallbacks',
    'Import-AdditionalTestRecordingHelper'
)
