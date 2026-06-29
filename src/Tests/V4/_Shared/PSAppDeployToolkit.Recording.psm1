$script:recordingStarted = $false
$script:recordingStopAttempted = $false
$script:recordingOutputFile = $null
$script:helperLoaded = $false

function Start-AdditionalTestRecording
{
    #Import-AdditionalTestRecordingHelper firstly to ensure the helper is loaded before attempting to start recording.
    if (-not $script:helperLoaded)
    {
        Import-AdditionalTestRecordingHelper
        $script:helperLoaded = $true
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
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    try
    {
        $candidatePaths = @(
            $env:TERRAFORGE_HELPER_PATH,
            'C:\PSADTScripts\TerraForge-AgentHelper.ps1',
            (Join-Path $ScriptRoot 'TerraForge-AgentHelper.ps1'),
            (Join-Path $ScriptRoot '.github\scripts\TerraForge-AgentHelper.ps1'),
            (Join-Path $ScriptRoot '..\.github\scripts\TerraForge-AgentHelper.ps1'),
            (Join-Path $ScriptRoot '..\..\..\..\.github\scripts\TerraForge-AgentHelper.ps1'),
            (if ($env:GITHUB_WORKSPACE) { Join-Path $env:GITHUB_WORKSPACE 'TerraForge-AgentHelper.ps1' } else { $null }),
            (if ($env:GITHUB_WORKSPACE) { Join-Path $env:GITHUB_WORKSPACE 'PSAppDeployToolkit\.github\scripts\TerraForge-AgentHelper.ps1' } else { $null })
        ) | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) }

        $helperScriptPath = $candidatePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

        if ($helperScriptPath)
        {
            . $helperScriptPath
            $script:helperLoaded = $true
            Write-ADTLogEntry -Message "Loaded TerraForge helper from path: $helperScriptPath" -Severity Info
        }
        else
        {
            $searchedPaths = $candidatePaths -join '; '
            Write-ADTLogEntry -Message "TerraForge-AgentHelper.ps1 not found. Paths checked: $searchedPaths. Skipping recording start." -Severity Warning
        }
    }
    catch
    {
        Write-ADTLogEntry -Message "Failed to load TerraForge-AgentHelper.ps1. Skipping recording integration. $($_.Exception.Message)" -Severity Warning
    }
}

Export-ModuleMember -Function @(
    'Start-AdditionalTestRecording',
    'Stop-AdditionalTestRecording',
    'Register-AdditionalTestRecordingCallbacks',
    'Import-AdditionalTestRecordingHelper'
)