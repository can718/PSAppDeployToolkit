$script:recordingStarted = $false
$script:recordingStopAttempted = $false
$script:recordingOutputFile = $null
$script:helperLoaded = $false
$script:terraForgeHelperModule = $null

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

    if (-not $script:terraForgeHelperModule -or -not (Get-Command -Name Stop-TerraForgeRecording -Module $script:terraForgeHelperModule -CommandType Function -ErrorAction SilentlyContinue))
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

function Register-AdditionalTestRecordingCallbacks
{
    Add-ADTModuleCallback -Hookpoint PostOpen -Callback (Get-Command -Name Start-AdditionalTestRecording)
    Add-ADTModuleCallback -Hookpoint OnFinish -Callback (Get-Command -Name Stop-AdditionalTestRecording)
}

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
    'Stop-AdditionalTestRecording',
    'Register-AdditionalTestRecordingCallbacks',
    'Import-AdditionalTestRecordingHelper'
)