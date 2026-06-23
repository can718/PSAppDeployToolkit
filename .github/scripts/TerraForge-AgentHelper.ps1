

function Get-TerraForgeAuthToken
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter()]
        [string]$ManagedIdentityClientId = $env:INFRA_MI_CLIENT_ID,

        [Parameter()]
        [string]$KeyVaultName = $env:INFRA_KEYVAULT,

        [Parameter()]
        [string]$ApiKeySecretName = $env:TERRAFORGE_API_KEY_SECRET,

        [Parameter(Mandatory)]
        [string]$ApiBaseUrl
    )

    # Step 1 - Login
    Connect-AzureWithManagedIdentity -ClientId $ManagedIdentityClientId

    # Step 2 - Get API access key from Key Vault
    $apiKey = Get-TerraForgeApiKey -SecretName $ApiKeySecretName -VaultName $KeyVaultName

    # Step 3 - Exchange for bearer token
    return Get-TerraForgeAccessToken -ApiBaseUrl $ApiBaseUrl -ApiAccessKey $apiKey
}

function Connect-AzureWithManagedIdentity
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ClientId
    )

    Write-Host "Connecting to Azure with Managed Identity (ClientId: $ClientId)..."
    Connect-AzAccount -Identity -AccountId $ClientId | Out-Null
    Write-Host "Connected to Azure successfully."
}

function Get-TerraForgeApiKey
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$SecretName,

        [Parameter(Mandatory)]
        [string]$VaultName
    )

    Write-Host "Retrieving TerraForge API key from Key Vault '$VaultName', secret '$SecretName'..."
    $apiKey = Get-AzKeyVaultSecret -SecretName $SecretName -VaultName $VaultName -AsPlainText
    return $apiKey
}

function Get-TerraForgeAccessToken
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$ApiAccessKey
    )

    $headers = @{
        "Content-Type"  = "application/json"
        "X-Client-Type" = "Automated"
    }
    $payload = @{ accessKey = $ApiAccessKey } | ConvertTo-Json

    Write-Host "Requesting TerraForge access token..."
    $response = Invoke-WebRequest -Uri "$ApiBaseUrl/api/auth/token" `
        -Method Post -Headers $headers -Body $payload -ErrorAction Stop
    $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

    if (-not ($content -and $content.data -and $content.data.accessToken))
    {
        throw "Failed to get access token from response: $($response.Content)"
    }

    return $content.data.accessToken
}

function Invoke-TerraForgeLaunchAgent
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$ConfigName,

        [Parameter()]
        [int]$PoolType = 3
    )

    $authHeaders = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
        "X-Client-Type" = "Automated"
    }
    $launchPayload = @{
        configName = $ConfigName
        poolType   = $PoolType
    } | ConvertTo-Json

    Write-Host "Sending discover agent request for config: $ConfigName ..."
    $launchResponse = Invoke-WebRequest -Uri "$ApiBaseUrl/api/v1/TestRun/Launch" `
        -Method Post -Headers $authHeaders -Body $launchPayload -ErrorAction Stop
    $launchContent = $launchResponse.Content | ConvertFrom-Json -ErrorAction Stop

    $machineId = $launchContent.data.machineIds[0]
    $agentName = "${machineId}_${ConfigName}"
    $machineUrl = "https://terraforge.southeastasia.cloudapp.azure.com/machines/$machineId"

    Write-Host "Launched agent machine: $agentName"
    Write-Host "Machine URL: $machineUrl"

    return [PSCustomObject]@{
        MachineId  = $machineId
        AgentName  = $agentName
        MachineUrl = $machineUrl
    }
}

function Set-GitHubOutput
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    Write-Host "GitHub output set: $Name=$Value"
}

function StartRecord
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$recordSavePath,

        [Parameter()]
        [string]$MachineIp
    )

    if (-not $MachineIp)
    {
        $MachineIp = Resolve-TerraForgeLocalIPv4
    }

    #$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    #$RecordSavePath = 'C:\Recordings\{0}_{1}.mp4' -f $recordSavePath, $timestamp
    $RecordSavePath = 'C:\Recordings\{0}.mp4' -f $recordSavePath
    Invoke-RestMethod -Uri ('http://{0}:8088/start?savingPath={1}' -f $MachineIp, $RecordSavePath)
}

function StopRecord
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$MachineIp,

        [Parameter()]
        [switch]$UploadToStorageAccount,

        [Parameter()]
        [string]$ApiBaseUrl = $env:TERRAFORGE_API_BASE_URL,

        [Parameter()]
        [string]$AccessToken,

        [Parameter()]
        [string]$TestRunId = $env:TEST_RUN_ID,

        [Parameter()]
        [string[]]$Files = @("$env:GITHUB_WORKSPACE\src\Artifacts\TestOutput\AdditionalTests.xml"),

        [Parameter()]
        [int]$UploadFileReadyTimeoutSeconds = 120,

        [Parameter()]
        [int]$UploadFileReadyPollSeconds = 2,

        [Parameter()]
        [string]$ManagedIdentityClientId = $env:INFRA_MI_CLIENT_ID,

        [Parameter()]
        [string]$KeyVaultName = $env:INFRA_KEYVAULT,

        [Parameter()]
        [string]$ApiKeySecretName = $env:TERRAFORGE_API_KEY_SECRET
    )

    if (-not $MachineIp)
    {
        $MachineIp = Resolve-TerraForgeLocalIPv4
    }

    Invoke-RestMethod -Uri ('http://{0}:8088/stop' -f $MachineIp)

    if ($UploadToStorageAccount)
    {
        if (-not $ApiBaseUrl) { $ApiBaseUrl = [System.Environment]::GetEnvironmentVariable('TERRAFORGE_API_BASE_URL', 'Machine') }
        if (-not $TestRunId) { $TestRunId = [System.Environment]::GetEnvironmentVariable('TEST_RUN_ID', 'Machine') }
        if (-not $ManagedIdentityClientId) { $ManagedIdentityClientId = [System.Environment]::GetEnvironmentVariable('INFRA_MI_CLIENT_ID', 'Machine') }
        if (-not $KeyVaultName) { $KeyVaultName = [System.Environment]::GetEnvironmentVariable('INFRA_KEYVAULT', 'Machine') }
        if (-not $ApiKeySecretName) { $ApiKeySecretName = [System.Environment]::GetEnvironmentVariable('TERRAFORGE_API_KEY_SECRET', 'Machine') }

        $missingUploadSettings = @(
            if (-not $ApiBaseUrl) { 'TERRAFORGE_API_BASE_URL' }
            if (-not $TestRunId) { 'TEST_RUN_ID' }
            if (-not $AccessToken -and -not $ManagedIdentityClientId) { 'INFRA_MI_CLIENT_ID' }
            if (-not $AccessToken -and -not $KeyVaultName) { 'INFRA_KEYVAULT' }
            if (-not $AccessToken -and -not $ApiKeySecretName) { 'TERRAFORGE_API_KEY_SECRET' }
        )
        if ($missingUploadSettings.Count -gt 0)
        {
            throw "Missing required TerraForge upload environment setting(s): $($missingUploadSettings -join ', ')."
        }
        if (-not $AccessToken)
        {
            $AccessToken = Get-TerraForgeAuthToken `
                -ApiBaseUrl              $ApiBaseUrl `
                -ManagedIdentityClientId $ManagedIdentityClientId `
                -KeyVaultName            $KeyVaultName `
                -ApiKeySecretName        $ApiKeySecretName
        }

        if ($Files -and $Files.Count -gt 0)
        {
            Wait-TerraForgeFilesReady `
                -Files              $Files `
                -TimeoutSeconds     $UploadFileReadyTimeoutSeconds `
                -PollSeconds        $UploadFileReadyPollSeconds
        }

        Copy-ResultsToAzureBlobStorage `
            -ApiBaseUrl  $ApiBaseUrl `
            -AccessToken $AccessToken `
            -TestRunId   $TestRunId `
            -Files       $Files
    }
}

function Wait-TerraForgeFilesReady
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string[]]$Files,

        [Parameter()]
        [int]$TimeoutSeconds = 120,

        [Parameter()]
        [int]$PollSeconds = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pendingFiles = @($Files)

    while ($pendingFiles.Count -gt 0 -and (Get-Date) -lt $deadline)
    {
        $stillPending = foreach ($file in $pendingFiles)
        {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf))
            {
                Write-Host "Waiting for upload file to exist: $file"
                $file
                continue
            }

            $firstLength = (Get-Item -LiteralPath $file).Length
            Start-Sleep -Seconds 1
            $secondLength = (Get-Item -LiteralPath $file).Length

            if ($firstLength -ne $secondLength)
            {
                Write-Host "Waiting for upload file to finish writing: $file"
                $file
            }
        }

        $pendingFiles = @($stillPending)
        if ($pendingFiles.Count -gt 0)
        {
            Start-Sleep -Seconds $PollSeconds
        }
    }

    foreach ($file in $pendingFiles)
    {
        Write-Warning "Upload file was not ready before timeout and will be skipped if still unavailable: $file"
    }
}

function Resolve-TerraForgeLocalIPv4
{
    [CmdletBinding()]
    [OutputType([string])]
    param ()

    $machineIp = [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.IPAddressToString } |
        Where-Object { $_ -ne '127.0.0.1' -and $_ -notlike '169.254.*' } |
        Select-Object -First 1

    if (-not $machineIp)
    {
        throw 'Unable to resolve local IPv4 address automatically. Please provide -MachineIp explicitly.'
    }

    return $machineIp
}

function Start-TerraForgeRecording
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param
    (
        [Parameter(Mandatory)]
        [string]$AppName,

        [Parameter()]
        [string]$DeploymentType,

        [Parameter()]
        [string]$FallbackRecordName = 'recording',

        [Parameter()]
        [string]$RecordingDirectory = 'C:\Recordings'
    )

    $result = [PSCustomObject]@{
        Started    = $false
        OutputFile = $null
    }

    if (-not (Get-Command -Name StartRecord -ErrorAction SilentlyContinue))
    {
        Write-Warning 'StartRecord function not found. Skipping recording start.'
        return $result
    }

    try
    {
        if ([System.String]::IsNullOrWhiteSpace($DeploymentType))
        {
            $DeploymentType = 'Install'
        }

        $rawRecordFileName = '{0}_{1}_{2}' -f $AppName, $DeploymentType, (Get-Date -Format 'yyyyMMdd_HHmmss')
        $invalidPattern = '[{0}]' -f [regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
        $recordFileName = ($rawRecordFileName -replace '\s+', '_' -replace $invalidPattern, '_').Trim(' ', '.')
        if ([System.String]::IsNullOrWhiteSpace($recordFileName))
        {
            $recordFileName = $FallbackRecordName
        }

        $outputFile = Join-Path -Path $RecordingDirectory -ChildPath "$recordFileName.mp4"
        StartRecord -recordSavePath $recordFileName
        Write-Host 'StartRecord succeeded.'

        $result.Started = $true
        $result.OutputFile = $outputFile
        return $result
    }
    catch
    {
        Write-Warning "StartRecord failed but deployment will continue: $($_.Exception.Message)"
        return $result
    }
}

function Stop-TerraForgeRecording
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param
    (
        [Parameter(Mandatory)]
        [bool]$RecordingStarted,

        [Parameter()]
        [string]$RecordingOutputFile,

        [Parameter()]
        [switch]$UploadToStorageAccount
    )

    $result = [PSCustomObject]@{
        StopAttempted       = $false
        StopSucceeded       = $false
        UploadRequested     = [bool]$UploadToStorageAccount
        UploadSucceeded     = $false
        RecordingOutputFile = $RecordingOutputFile
        Error               = $null
    }

    if (-not $RecordingStarted)
    {
        $result.Error = 'Recording was not started. Skipping recording stop and upload.'
        return $result
    }

    if (-not (Get-Command -Name StopRecord -ErrorAction SilentlyContinue))
    {
        $result.Error = 'StopRecord function not found. Skipping recording stop and upload.'
        Write-Warning $result.Error
        return $result
    }

    try
    {
        $result.StopAttempted = $true
        if ($RecordingOutputFile)
        {
            StopRecord -UploadToStorageAccount:$UploadToStorageAccount -Files @($RecordingOutputFile)
        }
        else
        {
            StopRecord -UploadToStorageAccount:$UploadToStorageAccount
        }

        $result.StopSucceeded = $true
        if ($UploadToStorageAccount)
        {
            if ($RecordingOutputFile -and -not (Test-Path -LiteralPath $RecordingOutputFile -PathType Leaf))
            {
                $result.Error = "Recording output file was not found after stopping recorder: $RecordingOutputFile"
            }
            else
            {
                $result.UploadSucceeded = $true
            }
        }
        Write-Host 'StopRecord succeeded.'
        return $result
    }
    catch
    {
        $result.Error = "StopRecord failed but deployment completion will continue: $($_.Exception.Message)"
        Write-Warning $result.Error
        return $result
    }
}

function Assert-PSADTDeploymentLogContent
{
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param
    (
        [Parameter()]
        [string]$LogFolder = 'C:\Windows\Logs\Software',

        [Parameter()]
        [string]$LogFileName,

        [Parameter()]
        [string[]]$ValidationContent = @(''),

        [Parameter()]
        [string]$AppVendor,

        [Parameter()]
        [string]$AppName,

        [Parameter()]
        [string]$AppVersion,

        [Parameter()]
        [string]$AppArch,

        [Parameter()]
        [string]$AppLang,

        [Parameter()]
        [string]$AppRevision,

        [Parameter()]
        [ValidateSet('Install', 'Uninstall', 'Repair')]
        [string]$DeploymentType = 'Install',

        [Parameter()]
        [switch]$PassThru
    )

    $metadata = [ordered]@{
        AppVendor   = $AppVendor
        AppName     = $AppName
        AppVersion  = $AppVersion
        AppArch     = $AppArch
        AppLang     = $AppLang
        AppRevision = $AppRevision
    }
    $missingMetadata = @($metadata.GetEnumerator() | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object { $_.Key })
    $installName = $null

    if ($missingMetadata.Count -eq 0)
    {
        $rawInstallName = '{0}_{1}_{2}_{3}_{4}_{5}' -f $AppVendor, $AppName, $AppVersion, $AppArch, $AppLang, $AppRevision
        $invalidPattern = '[{0}]' -f [regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
        $installName = ($rawInstallName.Trim('_') -replace '\s+', '' -replace '_+', '_') -replace $invalidPattern, ''
    }

    if ([string]::IsNullOrWhiteSpace($LogFileName))
    {
        if ($missingMetadata.Count -gt 0)
        {
            throw "Cannot generate PSADT log file name. Missing application metadata: $($missingMetadata -join ', ')."
        }

        $LogFileName = '{0}_PSAppDeployToolkit_{1}.log' -f $installName, $DeploymentType
    }
    elseif ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($LogFileName)))
    {
        $LogFileName = "$LogFileName.log"
    }

    $hasValidationContent = @($ValidationContent | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if (-not $hasValidationContent)
    {
        if ($missingMetadata.Count -gt 0)
        {
            throw "ValidationContent is required when application metadata is incomplete. Missing application metadata: $($missingMetadata -join ', ')."
        }

        $deploymentTypeText = $DeploymentType.ToLowerInvariant()
        $escapedInstallName = [regex]::Escape($installName)
        $escapedDeploymentType = [regex]::Escape($deploymentTypeText)
        $ValidationContent = @(
            "\[$escapedInstallName\]\s+$escapedDeploymentType completed in \[\d+(?:\.\d+)?\]\s+seconds with exit code \[0\]\."
        )
    }

    $logPath = if ([System.IO.Path]::IsPathRooted($LogFileName))
    {
        $LogFileName
    }
    else
    {
        Join-Path -Path $LogFolder -ChildPath $LogFileName
    }

    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf))
    {
        throw "PSADT deployment log file was not found: $logPath"
    }

    $logContent = Get-Content -LiteralPath $logPath -Raw -ErrorAction Stop
    $missingContent = @(
        foreach ($expectedContent in $ValidationContent)
        {
            if ([string]::IsNullOrWhiteSpace($expectedContent))
            {
                continue
            }

            if (-not [regex]::IsMatch($logContent, $expectedContent, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase))
            {
                $expectedContent
            }
        }
    )

    $result = [PSCustomObject]@{
        Succeeded       = ($missingContent.Count -eq 0)
        LogPath         = $logPath
        LogFileName     = [System.IO.Path]::GetFileName($logPath)
        ValidationCount = @($ValidationContent | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        MissingContent  = $missingContent
    }

    if (-not $result.Succeeded)
    {
        throw "PSADT deployment log validation failed for '$logPath'. Missing content: $($missingContent -join ' | ')"
    }

    Write-Host "PSADT deployment log validation passed: $logPath"
    if ($PassThru)
    {
        return $result
    }
}

#region Registry Helpers

function Get-RegistryValue
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$Path = 'HKLM:\SOFTWARE\Microsoft\TerraforgeAgent',

        [Parameter()]
        [string]$Name
    )

    if (-not (Test-Path $Path))
    {
        return $null
    }

    $value = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($value)
    {
        return $value.$Name
    }
    else
    {
        return $null
    }
}

function Set-RegistryValue
{
    <#
    .SYNOPSIS
        Writes a value to the Windows registry, creating the key if necessary.
    .PARAMETER Path
        The registry key path. Defaults to the TerraForge agent registry path.
    .PARAMETER Name
        The name of the registry value to write.
    .PARAMETER Value
        The value to write.
    .PARAMETER Type
        The registry value type (default: String).
    #>
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$Path = 'HKLM:\SOFTWARE\Microsoft\TerraforgeAgent',

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter()]
        [Microsoft.Win32.RegistryValueKind]$Type = [Microsoft.Win32.RegistryValueKind]::String
    )

    if (-not (Test-Path $Path))
    {
        New-Item -Path $Path -Force | Out-Null
    }

    if ($Type -eq [Microsoft.Win32.RegistryValueKind]::DWord)
    {
        if ($Value -is [bool])
        {
            $Value = [int]$Value
        }
        elseif ($Value -in 'True', 'true', '1')
        {
            $Value = 1
        }
        elseif ($Value -in 'False', 'false', '0')
        {
            $Value = 0
        }
        else
        {
            try
            {
                $Value = [int]$Value
            }
            catch
            {
                throw "Cannot convert value '$Value' to integer for DWord registry type."
            }
        }
    }

    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Append-RegistryValue
{
    <#
    .SYNOPSIS
        Appends a value to an existing registry string value, creating the key if necessary.
    .PARAMETER Path
        The registry key path. Defaults to the TerraForge agent registry path.
    .PARAMETER Name
        The name of the registry value to append to.
    .PARAMETER Value
        The value to append.
    .PARAMETER Separator
        The separator to use between existing and new value (default: ';').
    .PARAMETER Type
        The registry value type (default: String).
    #>
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$Path = 'HKLM:\SOFTWARE\Microsoft\TerraforgeAgent',

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter()]
        [string]$Separator = ';',

        [Parameter()]
        [Microsoft.Win32.RegistryValueKind]$Type = [Microsoft.Win32.RegistryValueKind]::String
    )

    if (-not (Test-Path $Path))
    {
        New-Item -Path $Path -Force | Out-Null
    }

    $existingValue = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    $currentValue = if ($existingValue) { $existingValue.$Name } else { $null }

    if ([string]::IsNullOrWhiteSpace($currentValue))
    {
        $newValue = $Value
    }
    else
    {
        $newValue = "{0}{1}{2}" -f $currentValue, $Separator, $Value
    }

    Set-ItemProperty -Path $Path -Name $Name -Value $newValue -Type $Type -Force
}

function Get-SessionID
{
    [CmdletBinding()]
    param ()
    return Get-RegistryValue -Name 'SessionID'
}

function Get-ConfigName
{
    [CmdletBinding()]
    param ()
    return Get-RegistryValue -Name 'ConfigName'
}

function Get-MachineID
{
    [CmdletBinding()]
    param ()
    $machineId = Get-RegistryValue -Name 'MachineID'
    if ($machineId)
    {
        return $machineId
    }
    else
    {
        return $env:COMPUTERNAME.ToLower()
    }
}

#endregion

function Get-AzureKeyVaultSecretValue
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$SecretName,

        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$ManagedIdentityClientId,

        [Parameter()]
        [switch]$AsPlainText,

        [Parameter()]
        [int]$RetryCount = 3
    )

    $attempt = $RetryCount
    while ($attempt -gt 0)
    {
        try
        {
            Start-Sleep -Seconds 3

            $ctx = Get-AzContext
            while ($ctx)
            {
                Write-Verbose "Clearing existing Azure context for account: $($ctx.Account)"
                Disconnect-AzAccount -ErrorAction SilentlyContinue
                Clear-AzContext -Force -ErrorAction SilentlyContinue
                $ctx = Get-AzContext
            }

            Write-Host "Connecting to Azure (ManagedIdentity: $ManagedIdentityClientId)..."
            Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId | Out-Null
            Write-Host "Retrieving secret '$SecretName' from Key Vault '$VaultName'..."

            if ($AsPlainText)
            {
                $secretValue = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -AsPlainText
                return @{
                    SecretValue = $secretValue
                }
            }
            else
            {
                $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName
                if (-not $secret.SecretValue)
                {
                    throw "Secret '$SecretName' returned an empty value."
                }
                return $secret
            }
        }
        catch
        {
            $attempt--
            Write-Warning "Failed to retrieve secret (attempts left: $attempt): $($_.Exception.Message)"
            if ($attempt -eq 0)
            {
                throw "Failed to retrieve secret '$SecretName' after $RetryCount attempts: $($_.Exception.Message)"
            }
        }
    }
}

function Get-SessionAdministratorSecretName
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [int]$SessionId,

        [Parameter(Mandatory)]
        [string]$MachineId,

        [Parameter()]
        [string]$Username = 'Administrator'
    )

    $secretName = "$SessionId-$MachineId-$Username"
    Write-Verbose "Session administrator secret name: $secretName"
    return $secretName
}

function Get-SessionAdministratorCredential
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [int]$SessionId,

        [Parameter(Mandatory)]
        [string]$MachineId,

        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$ManagedIdentityClientId,

        [Parameter()]
        [string]$Username = 'Administrator'
    )

    $secretName = Get-SessionAdministratorSecretName -SessionId $SessionId -MachineId $MachineId -Username $Username
    Write-Host "Retrieving administrator credential from Key Vault '$VaultName', secret '$secretName'..."

    $secret = Get-AzureKeyVaultSecretValue `
        -SecretName $secretName `
        -VaultName $VaultName `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -AsPlainText

    $securePassword = ConvertTo-SecureString -AsPlainText -Force -String $secret.SecretValue
    return [System.Management.Automation.PSCredential]::new($Username, $securePassword)
}

function Get-AzureKeyVaultCertificate
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$KeyVaultName,

        [Parameter(Mandatory)]
        [string]$CertificateName,

        [Parameter(Mandatory)]
        [string]$ManagedIdentityClientId,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    # Disable progress bar to improve download speed
    $ProgressPreference = 'SilentlyContinue'

    # Ensure the output directory exists
    $outputDir = [System.IO.Path]::GetDirectoryName($OutputPath)
    if (-not (Test-Path $outputDir))
    {
        New-Item -Path $outputDir -ItemType Directory -Force | Out-Null
        Write-Host "Created output directory: $outputDir"
    }

    # Authenticate using User-Assigned Managed Identity
    Write-Host "Connecting to Azure with Managed Identity (ClientId: $ManagedIdentityClientId)..."
    Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId | Out-Null
    Write-Host "Connected to Azure successfully."

    # Retrieve certificate secret (base64-encoded PFX) from Key Vault
    Write-Host "Downloading certificate '$CertificateName' from Key Vault '$KeyVaultName'..."
    $secretBase64 = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $CertificateName -AsPlainText

    if ([string]::IsNullOrEmpty($secretBase64))
    {
        throw "Retrieved empty secret for certificate '$CertificateName' from Key Vault '$KeyVaultName'. Verify the certificate name and access permissions."
    }

    # Decode base64 and write PFX bytes to disk
    $certBytes = [Convert]::FromBase64String($secretBase64)
    [System.IO.File]::WriteAllBytes($OutputPath, $certBytes)

    Write-Host "Certificate downloaded successfully: $OutputPath"
}

#endregion

#region TerraForge VM Lifecycle

function Start-AzureSessionVM
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter()]
        [string]$ConfigName = 'PSADT-AppRunner',

        [Parameter()]
        [int]$PoolType = 3,

        [Parameter()]
        [string]$OsName = 'Windows11',

        [Parameter()]
        [string]$Architecture = 'X64',

        [Parameter()]
        [string]$AdoBuildId
    )

    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRun/Activate"
    $payload = @{
        configName   = $ConfigName
        poolType     = $PoolType
        osName       = $OsName
        architecture = $Architecture
        AdoBuildId   = $AdoBuildId
    } | ConvertTo-Json

    try
    {
        Write-Host "Starting Azure session VM (config: $ConfigName)..."
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.data.machineId -or -not $content.data.sessionId)
        {
            throw "Invalid response received from $uri"
        }

        Write-Host "Started VM -- MachineId: $($content.data.machineId), SessionId: $($content.data.sessionId), IP: $($content.data.ipAddress)"
        return @{
            MachineId = $content.data.machineId
            SessionId = $content.data.sessionId
            IPAddress = $content.data.ipAddress
        }
    }
    catch
    {
        if ($_.Exception.Message -match '404')
        {
            Write-Warning "Start-AzureSessionVM: resource not found (404). Returning null."
            return $null
        }
        throw "Failed to start Azure session VM: $($_.Exception.Message)"
    }
}

function Reset-AzureSessionVM
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$MachineId,

        [Parameter()]
        [int]$TestStatus
    )

    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRun/Reset"
    $payload = @{
        results = @(
            @{
                machineId    = $MachineId
                status       = $TestStatus
                isForceReset = $false
            }
        )
    } | ConvertTo-Json

    try
    {
        Write-Host "Resetting Azure session VM (MachineId: $MachineId)..."
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success)
        {
            throw "Invalid response received from $uri"
        }
        Write-Host "Azure session VM '$MachineId' reset successfully."
    }
    catch
    {
        throw "Failed to reset Azure session VM '$MachineId': $($_.Exception.Message)"
    }
}

function Get-AzureVMStatus
{
    <#
    .SYNOPSIS
        Retrieves the power status of a TerraForge Azure VM.
    .PARAMETER ApiBaseUrl
        The TerraForge API base URL.
    .PARAMETER AccessToken
        The bearer access token.
    .PARAMETER MachineId
        The machine ID to query.
    .OUTPUTS
        [string] Friendly power state name (e.g. 'Running', 'Deallocated').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$MachineId
    )

    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/Machines/$MachineId/PowerStatus"

    try
    {
        Write-Host "Getting power status for VM '$MachineId'..."
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success)
        {
            throw "Invalid response received from $uri"
        }
        Write-Host "VM '$MachineId' status: $($content.data.powerStateFriendlyName)"
        return $content.data.powerStateFriendlyName
    }
    catch
    {
        throw "Failed to get Azure VM status for '$MachineId': $($_.Exception.Message)"
    }
}

#endregion

#region TerraForge Storage

function Get-TFPFSStorageAccountAccessKey
{
    <#
    .SYNOPSIS
        Retrieves the TFPFS storage account access key via the TerraForge API.
    .PARAMETER ApiBaseUrl
        The TerraForge API base URL.
    .PARAMETER AccessToken
        The bearer access token.
    .OUTPUTS
        [string] The storage account access key value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/KeyVault/Secret/TFPFSStorageAccountAccessKey"

    try
    {
        Write-Host "Retrieving TFPFS storage account access key..."
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success)
        {
            throw "Invalid response received from $uri"
        }
        Write-Host "TFPFS storage account access key retrieved successfully."
        return $content.data.value
    }
    catch
    {
        throw "Failed to retrieve TFPFS storage account access key: $($_.Exception.Message)"
    }
}

function Start-AzCopy
{
    <#
    .SYNOPSIS
        Copies files using AzCopy with MSI authentication.
    .PARAMETER Source
        The source path or URL.
    .PARAMETER Destination
        The destination path or URL.
    .PARAMETER ManagedIdentityClientId
        The Managed Identity client ID for AzCopy MSI login.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [string]$ManagedIdentityClientId
    )

    $env:AZCOPY_AUTO_LOGIN_TYPE = 'MSI'
    $env:AZCOPY_MSI_CLIENT_ID = $ManagedIdentityClientId

    try
    {
        Write-Host "Starting AzCopy: '$Source' -> '$Destination'"
        $result = & azcopy copy $Source $Destination 2>&1
        $result | ForEach-Object { Write-Verbose "AzCopy: $_" }

        if ($LASTEXITCODE -ne 0)
        {
            throw "AzCopy exited with code $LASTEXITCODE for source: $Source"
        }
        Write-Host "AzCopy completed successfully for '$Source'."
    }
    catch
    {
        throw "AzCopy encountered an error: $($_.Exception.Message)"
    }
}

function Copy-ResultsToAzureBlobStorage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$TestRunId,

        [Parameter()]
        [string[]]$Files
    )

    # Retrieve storage account access key via TerraForge API
    $TFPFSStorageAccountAccessKey = Get-TFPFSStorageAccountAccessKey -ApiBaseUrl $ApiBaseUrl -AccessToken $AccessToken

    # Ensure Az.Storage module is available
    if (-not (Get-Module -ListAvailable Az.Storage))
    {
        Write-Host "Az.Storage module not found. Installing..."
        Install-Module -Name Az.Storage -Scope AllUsers -Force -Confirm:$false
        Import-Module -Name Az.Storage
        if (Get-Module -Name Az.Storage)
        {
            Write-Host "Az.Storage module imported successfully."
        }
        else
        {
            throw "Az.Storage module import failed."
        }
    }
    else
    {
        Write-Host "Az.Storage module already available."
        Import-Module -Name Az.Storage
        if (Get-Module -Name Az.Storage)
        {
            Write-Host "Az.Storage module imported successfully."
        }
        else
        {
            throw "Az.Storage module import failed."
        }
    }

    $ctx = New-AzStorageContext -StorageAccountName 'tfpfsstorage' -StorageAccountKey $TFPFSStorageAccountAccessKey

    # Upload each file
    if ($Files -and $Files.Count -gt 0)
    {
        foreach ($file in $Files)
        {
            if (Test-Path $file)
            {
                $fileName = Split-Path $file -Leaf
                $blobPath = "testruns/{0}/{1}" -f $TestRunId, $fileName
                Write-Host "Uploading '$fileName' to Azure Blob Storage: $blobPath"
                $null = Set-AzStorageBlobContent -File $file `
                    -Container 'tfp-shares' `
                    -Blob $blobPath `
                    -Context $ctx `
                    -Force
                Write-Host "Uploaded successfully: $blobPath"
            }
            else
            {
                Write-Warning "File '$file' not found, skipping upload."
            }
        }
    }
    else
    {
        Write-Host "No files specified, skipping upload."
    }
}

function Get-AzureBlobStorageFolderToLocal
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$BlobFolderPath,

        [Parameter(Mandatory)]
        [string]$LocalDestinationDir
    )

    # Retrieve storage account access key via TerraForge API
    $TFPFSStorageAccountAccessKey = Get-TFPFSStorageAccountAccessKey -ApiBaseUrl $ApiBaseUrl -AccessToken $AccessToken

    # Ensure Az.Storage module is available
    if (-not (Get-Module -ListAvailable Az.Storage))
    {
        Write-Host "Az.Storage module not found. Installing..."
        Install-Module -Name Az.Storage -Scope AllUsers -Force -Confirm:$false
        Import-Module -Name Az.Storage
        if (Get-Module -Name Az.Storage)
        {
            Write-Host "Az.Storage module imported successfully."
        }
        else
        {
            throw "Az.Storage module import failed."
        }
    }
    else
    {
        Write-Host "Az.Storage module already available."
        Import-Module -Name Az.Storage
        if (Get-Module -Name Az.Storage)
        {
            Write-Host "Az.Storage module imported successfully."
        }
        else
        {
            throw "Az.Storage module import failed."
        }
    }

    # Ensure local destination directory exists
    if (-not (Test-Path $LocalDestinationDir))
    {
        New-Item -ItemType Directory -Force -Path $LocalDestinationDir | Out-Null
        Write-Host "Created local destination directory: $LocalDestinationDir"
    }

    $ctx = New-AzStorageContext -StorageAccountName 'tfpfsstorage' -StorageAccountKey $TFPFSStorageAccountAccessKey

    # List all blobs under the specified folder prefix
    $blobs = Get-AzStorageBlob -Container 'tfp-shares' -Prefix $BlobFolderPath -Context $ctx

    if (-not $blobs -or $blobs.Count -eq 0)
    {
        Write-Host "No blobs found under '$BlobFolderPath', skipping download."
        return
    }

    # Normalise the prefix so we can strip it to get the relative path
    $folderPrefix = $BlobFolderPath.TrimEnd('/')

    foreach ($blob in $blobs)
    {
        $blobName = $blob.Name

        # Compute relative path by stripping the folder prefix, then convert '/' to '\'
        $relativePath = $blobName.Substring($folderPrefix.Length).TrimStart('/').Replace('/', '\')
        $localFilePath = Join-Path $LocalDestinationDir $relativePath

        # Ensure the sub-directory exists before downloading
        $localFileDir = Split-Path $localFilePath -Parent
        if (-not (Test-Path $localFileDir))
        {
            New-Item -ItemType Directory -Force -Path $localFileDir | Out-Null
        }

        Write-Host "Downloading blob '$blobName' to '$localFilePath'..."
        try
        {
            $null = Get-AzStorageBlobContent `
                -Container   'tfp-shares' `
                -Blob        $blobName `
                -Destination $localFilePath `
                -Context     $ctx `
                -Force
            Write-Host "Downloaded successfully: $localFilePath"
        }
        catch
        {
            Write-Warning "Failed to download '$blobName': $($_.Exception.Message)"
        }
    }
}

#endregion

#region Test Run Management

function Set-TestRun
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [ValidateSet('Start', 'Complete')]
        [string]$Action,

        [Parameter()]
        [string]$MachineId,

        [Parameter()]
        [string]$ConfigName = 'PSADT-Agent',

        [Parameter()]
        [bool]$IsDevOpsAgent = $true,

        [Parameter()]
        [string]$TestRunId, 

        [Parameter()]
        [string]$AdoBuildId,

        [Parameter()]
        [string]$Product = 'PSADT',

        [Parameter()]
        [string]$Title,

        [Parameter()]
        [string]$QueuedBy,

        [Parameter()]
        [string]$BranchName,

        [Parameter()]
        [string]$SessionId
    )


    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    if ($Action -eq 'Start')
    {
        # if sessionID is not provided, set it to current sessionID
        if (-not $SessionId)
        {
            $SessionId = Get-SessionID
        }
        $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRun/Start"
        $payload = @{
            MachineId     = $MachineId
            ConfigName    = $ConfigName
            IsDevOpsAgent = $IsDevOpsAgent
            AdoBuildId    = if ($AdoBuildId) { [int64]$AdoBuildId } else { $null }
            Product       = $Product
            Title         = $Title
            QueuedBy      = $QueuedBy
            BranchName    = $BranchName
            SessionId     = if ($SessionId) { [int64]$SessionId } else { $null }
        } | ConvertTo-Json -Depth 5
    }
    else
    {
        $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRun/Complete"
        $payload = @{
            Id            = [int64]$TestRunId
            IsDevOpsAgent = $IsDevOpsAgent
        } | ConvertTo-Json -Depth 5
    }

    try
    {
        Write-Host "$Action test run (MachineId: $MachineId)..."
        Write-Host "URI    : $uri"
        Write-Host "Payload: $payload"
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success)
        {
            throw "Invalid response received from $uri"
        }
        Write-Host "Test run '$Action' succeeded. Id: $($content.data.id)"
        return @{
            Id = $content.data.id
        }
    }
    catch
    {
        # Surface the full response body to aid debugging
        $responseBody = $null
        try { $responseBody = $_.ErrorDetails.Message } catch {}
        $detail = if ($responseBody) { " | Response: $responseBody" } else { '' }
        throw "Failed to $Action test run: $($_.Exception.Message)$detail"
    }
}

function New-TestRunResults
{
    <#
    .SYNOPSIS
        Creates a new test run result entry in TerraForge.
    .PARAMETER ApiBaseUrl
        The TerraForge API base URL.
    .PARAMETER AccessToken
        The bearer access token.
    .PARAMETER TestRunId
        The parent test run ID.
    .PARAMETER MachineId
        The machine ID.
    .PARAMETER TestClass
        The test class name.
    .PARAMETER SessionId
        Optional session ID.
    .PARAMETER ProductName
        Optional product/method name.
    .PARAMETER TestCaseId
        Optional test case ID (default: 0).
    .OUTPUTS
        Hashtable with key 'Id' containing the created result ID.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$TestRunId,

        [Parameter()]
        [string]$MachineId = $env:COMPUTERNAME,

        [Parameter(Mandatory)]
        [string]$TestClass,

        [Parameter()]
        [string]$SessionId,

        [Parameter()]
        [string]$ProductName,

        [Parameter()]
        [string]$TestCaseId = '0'
    )

    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }
    # if sessionID is not provided, set it to current sessionID
    if (-not $SessionId)
    {
        $SessionId = Get-SessionID
    }
    # if machineID is not provided, set it to current machineID
    if (-not $MachineId)
    {
        $MachineId = $env:COMPUTERNAME
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRunResults/Create"
    $payload = @{
        MachineId      = $MachineId
        SessionId      = if ($SessionId) { [int64]$SessionId } else { $null }
        TestRunId      = $TestRunId
        TestCaseId     = $TestCaseId
        Owner          = 'PSADT-Test-Team'
        TestClass      = $TestClass
        TestMethod     = $ProductName
        Result         = 3
        StartedTimeUtc = (Get-Date).ToUniversalTime()
        Category       = 'SNAP'
    } | ConvertTo-Json
    # Write-Host "Payload: $payload"
    try
    {
        Write-Host "Creating test run result (TestRunId: $TestRunId, MachineId: $MachineId)..."
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success)
        {
            throw "Invalid response received from $uri"
        }
        Write-Host "Test run result created. Id: $($content.data.id)"
        return @{ Id = $content.data.id }
    }
    catch
    {
        throw "Failed to create test run result: $($_.Exception.Message)"
    }
}

function Update-TestRunResults
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$TestRunResultId,

        [Parameter(Mandatory)]
        [int]$Result,

        [Parameter()]
        [string]$ErrorMessage
    )

    $headers = @{
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRunResults/Update/$TestRunResultId"
    $payload = @{
        TestRunResultId = $TestRunResultId
        Result          = $Result
        FinishedTimeUtc = (Get-Date).ToUniversalTime()
        ErrorMessage    = $ErrorMessage
    } | ConvertTo-Json

    try
    {
        Write-Host "Updating test run result '$TestRunResultId' with result code $Result..."
        $response = Invoke-WebRequest -Uri $uri -Method Patch -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success)
        {
            throw "Invalid response received from $uri"
        }
        Write-Host "Test run result '$TestRunResultId' updated successfully."
        return @{ Id = $content.data.id }
    }
    catch
    {
        throw "Failed to update test run result '$TestRunResultId': $($_.Exception.Message)"
    }
}

#endregion

#region Workflow Teardown

function Invoke-TFLaunchAgent
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$ApiBaseUrl = $env:TERRAFORGE_API_BASE_URL,

        [Parameter()]
        [string]$ConfigName = $env:TERRAFORGE_CONFIG_NAME,

        [Parameter()]
        [int]$MaxRetries = 12,

        [Parameter()]
        [int]$RetryDelaySeconds = 5,

        [Parameter()]
        [string]$ManagedIdentityClientId = $env:INFRA_MI_CLIENT_ID,

        [Parameter()]
        [string]$KeyVaultName = $env:INFRA_KEYVAULT,

        [Parameter()]
        [string]$ApiKeySecretName = $env:TERRAFORGE_API_KEY_SECRET
    )

    $attempt = 0
    while ($true)
    {
        $attempt++
        Write-Host "==> Launch agent attempt $attempt / $MaxRetries (Config: $ConfigName) ..."

        try
        {
            # Re-authenticate on every attempt -- the access token may expire during long waits
            $accessToken = Get-TerraForgeAuthToken `
                -ApiBaseUrl              $ApiBaseUrl `
                -ManagedIdentityClientId $ManagedIdentityClientId `
                -KeyVaultName            $KeyVaultName `
                -ApiKeySecretName        $ApiKeySecretName

            $agent = Invoke-TerraForgeLaunchAgent `
                -ApiBaseUrl  $ApiBaseUrl `
                -AccessToken $accessToken `
                -ConfigName  $ConfigName

            # Success -- expose the runner label and return
            Set-GitHubOutput -Name 'runner-label' -Value $agent.AgentName
            return $agent
        }
        catch
        {
            $errMsg = $_.Exception.Message

            if ($attempt -ge $MaxRetries)
            {
                throw "Failed to launch agent after $MaxRetries attempts. Last error: $errMsg"
            }

            # Treat any failure as a transient "busy / unavailable" condition and retry
            Write-Warning "Attempt $attempt failed: $errMsg"
            Write-Host "All machines may be busy. Waiting $RetryDelaySeconds seconds before retry..."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Invoke-TFStartTestRun
{
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter()]
        [string]$ApiBaseUrl = $env:TERRAFORGE_API_BASE_URL,

        [Parameter()]
        [string]$ConfigName = $env:TERRAFORGE_CONFIG_NAME,

        [Parameter()]
        [string]$AdoBuildId = $env:GITHUB_RUN_ID,

        [Parameter()]
        [string]$QueuedBy = $env:GITHUB_ACTOR,

        [Parameter()]
        [string]$Title,

        [Parameter()]
        [string]$Product = 'PSADT',

        [Parameter()]
        [string]$ManagedIdentityClientId = $env:INFRA_MI_CLIENT_ID,

        [Parameter()]
        [string]$KeyVaultName = $env:INFRA_KEYVAULT,

        [Parameter()]
        [string]$ApiKeySecretName = $env:TERRAFORGE_API_KEY_SECRET
    )

    $accessToken = Get-TerraForgeAuthToken `
        -ApiBaseUrl              $ApiBaseUrl `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -KeyVaultName            $KeyVaultName `
        -ApiKeySecretName        $ApiKeySecretName

    $runTitle = if ($Title) { $Title } else { "$Product Tests - Build $AdoBuildId" }

    Write-Host "==> Starting test run (Config: $ConfigName, Build: $AdoBuildId) ..."
    $testRun = Set-TestRun `
        -ApiBaseUrl  $ApiBaseUrl `
        -AccessToken $accessToken `
        -Action      'Start' `
        -MachineId   $env:COMPUTERNAME `
        -ConfigName  $ConfigName `
        -AdoBuildId  $AdoBuildId `
        -Product     $Product `
        -Title       $runTitle `
        -QueuedBy    $QueuedBy

    Set-GitHubOutput -Name 'test-run-id' -Value $testRun.Id
    return $testRun.Id
}

function Invoke-TFCompleteTestRun
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$ApiBaseUrl = $env:TERRAFORGE_API_BASE_URL,

        [Parameter()]
        [string]$TestRunId = $env:TEST_RUN_ID,

        [Parameter()]
        [string]$ManagedIdentityClientId = $env:INFRA_MI_CLIENT_ID,

        [Parameter()]
        [string]$KeyVaultName = $env:INFRA_KEYVAULT,

        [Parameter()]
        [string]$ApiKeySecretName = $env:TERRAFORGE_API_KEY_SECRET
    )

    $accessToken = Get-TerraForgeAuthToken `
        -ApiBaseUrl              $ApiBaseUrl `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -KeyVaultName            $KeyVaultName `
        -ApiKeySecretName        $ApiKeySecretName

    Write-Host "==> Completing test run $TestRunId ..."
    Set-TestRun `
        -ApiBaseUrl  $ApiBaseUrl `
        -AccessToken $accessToken `
        -Action      'Complete' `
        -TestRunId   $TestRunId
}

function Invoke-TFUploadTestResults
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$ApiBaseUrl = $env:TERRAFORGE_API_BASE_URL,

        [Parameter()]
        [string]$TestRunId = $env:TEST_RUN_ID,

        [Parameter()]
        [string[]]$TestResultXmlPath = @("$env:GITHUB_WORKSPACE\src\Artifacts\TestOutput\AdditionalTests.xml"),

        [Parameter()]
        [string]$ManagedIdentityClientId = $env:INFRA_MI_CLIENT_ID,

        [Parameter()]
        [string]$KeyVaultName = $env:INFRA_KEYVAULT,

        [Parameter()]
        [string]$ApiKeySecretName = $env:TERRAFORGE_API_KEY_SECRET
    )

    $accessToken = Get-TerraForgeAuthToken `
        -ApiBaseUrl              $ApiBaseUrl `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -KeyVaultName            $KeyVaultName `
        -ApiKeySecretName        $ApiKeySecretName

    Write-Host "==> Uploading test results to Azure Blob Storage ..."
    Copy-ResultsToAzureBlobStorage `
        -ApiBaseUrl  $ApiBaseUrl `
        -AccessToken $accessToken `
        -TestRunId   $TestRunId `
        -Files       $TestResultXmlPath
    Write-Host "Test results copied to Azure Blob Storage."
}

function Invoke-TFDownloadTestAssets
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$ApiBaseUrl = $env:TERRAFORGE_API_BASE_URL,

        [Parameter()]
        [string]$BlobFolderPath = "tools/Intune/AutoEnroll",

        [Parameter()]
        [string]$LocalDestinationDir = "C:\Tools\PSADT\AutoEnroll",

        [Parameter()]
        [string]$KeyVaultName = $env:INFRA_KEYVAULT,

        [Parameter()]
        [string]$CertificateName = "PSADTIntune",

        [Parameter()]
        [string]$CertificateOutputPath = "C:\Tools\PSADT\AutoEnroll\AccountJSONs\pmpc5.pfx",

        [Parameter()]
        [string]$ManagedIdentityClientId = $env:INFRA_MI_CLIENT_ID,

        [Parameter()]
        [string]$KeyVaultApiKeySecretName = $env:TERRAFORGE_API_KEY_SECRET,

        [Parameter()]
        [string]$AADUserCode = $env:AAD_USER_CODE
    )

    # Step 1 - Download certificate from Key Vault
    Write-Host "==> Downloading certificate '$CertificateName' from Key Vault '$KeyVaultName' ..."
    Get-AzureKeyVaultCertificate `
        -KeyVaultName            $KeyVaultName `
        -CertificateName         $CertificateName `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -OutputPath              $CertificateOutputPath
    Write-Host "Certificate downloaded to: $CertificateOutputPath"

    # Step 2 - Obtain TerraForge access token
    Write-Host "==> Obtaining TerraForge access token ..."
    $accessToken = Get-TerraForgeAuthToken `
        -ApiBaseUrl              $ApiBaseUrl `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -KeyVaultName            $KeyVaultName `
        -ApiKeySecretName        $KeyVaultApiKeySecretName

    # Step 3 - Download blob folder to local destination
    Write-Host "==> Downloading blob folder '$BlobFolderPath' to '$LocalDestinationDir' ..."
    Get-AzureBlobStorageFolderToLocal `
        -ApiBaseUrl          $ApiBaseUrl `
        -AccessToken         $accessToken `
        -BlobFolderPath      $BlobFolderPath `
        -LocalDestinationDir $LocalDestinationDir
    Write-Host "Blob folder downloaded to: $LocalDestinationDir"
    # update file content with replaced AAD user code if placeholder exists
    #get directory of $CertificateOutputPath
    $TestAccountDir = [System.IO.Path]::GetDirectoryName($CertificateOutputPath)
    $TestAccountFile = Join-Path $TestAccountDir "TestAccounts.txt"
    if ($AADUserCode -and (Test-Path $TestAccountFile))
    {
        Write-Host "Updating test account file with AAD user code..."
        (Get-Content $TestAccountFile) -replace '{{AADUserCode}}', $AADUserCode | Set-Content $TestAccountFile
        Write-Host "Test account file updated: $TestAccountFile"
    }
    else
    {
        Write-Warning "AADUserCode not provided or test account file $TestAccountFile not found. Skipping test account update."
    }

    $EnrollFile = Join-Path $LocalDestinationDir "EnrollAutomation.exe"

    # Pre-import the PFX certificate into the CurrentUser\My store before running the exe.
    # The exe internally calls Import-PfxCertificate in a child process which may fail in
    # Session 0 / non-interactive runner environments. By importing first here (in the same
    # user context that owns the runner process), the certificate is guaranteed to be present
    # when the exe proceeds to the enrollment steps.
    if (Test-Path $CertificateOutputPath)
    {
        Write-Host "==> Pre-importing certificate '$CertificateOutputPath' into CurrentUser\My store..."
        try
        {
            $importedCert = Import-PfxCertificate `
                -FilePath         $CertificateOutputPath `
                -CertStoreLocation 'Cert:\CurrentUser\My' `
                -Exportable `
                -ErrorAction Stop
            Write-Host "Certificate pre-imported successfully. Thumbprint: $($importedCert.Thumbprint)"
        }
        catch
        {
            Write-Warning "Pre-import of certificate failed: $($_.Exception.Message). The exe will attempt its own import."
        }
    }
    else
    {
        Write-Warning "Certificate file not found at '$CertificateOutputPath', skipping pre-import."
    }


    $winPSModulesPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
    if ($env:PSModulePath -notlike "*$winPSModulesPath*")
    {
        Write-Host "==> Prepending Windows PowerShell module path to PSModulePath..."
        $env:PSModulePath = "$winPSModulesPath;$env:PSModulePath"
    }
    Write-Host "PSModulePath: $env:PSModulePath"

    Write-Host "==> Executing EnrollAutomation.exe (WorkingDirectory: $LocalDestinationDir)..."
    $process = Start-Process -FilePath $EnrollFile `
        -WorkingDirectory $LocalDestinationDir `
        -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -ne 0)
    {
        throw "EnrollAutomation.exe exited with code $($process.ExitCode)."
    }
    Write-Host "==> EnrollAutomation.exe completed successfully."

}

function Invoke-TFResetSessionVM
{
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$ApiBaseUrl = $env:TERRAFORGE_API_BASE_URL,

        [Parameter()]
        [string[]]$TestResultXmlPath = @("$env:GITHUB_WORKSPACE\src\Artifacts\TestOutput\AdditionalTests.xml"),

        [Parameter()]
        [string]$MachineId = (Get-MachineID),

        [Parameter()]
        [string]$ManagedIdentityClientId = $env:INFRA_MI_CLIENT_ID,

        [Parameter()]
        [string]$KeyVaultName = $env:INFRA_KEYVAULT,

        [Parameter()]
        [string]$ApiKeySecretName = $env:TERRAFORGE_API_KEY_SECRET
    )

    $accessToken = Get-TerraForgeAuthToken `
        -ApiBaseUrl              $ApiBaseUrl `
        -ManagedIdentityClientId $ManagedIdentityClientId `
        -KeyVaultName            $KeyVaultName `
        -ApiKeySecretName        $ApiKeySecretName

    $vmStatus = 4   # default: Failed

    # Check all XML result files -- if any file reports failures/errors/ignored, mark VM as Failed
    $anyXmlFound = $false
    $overallPassed = $true

    foreach ($xmlPath in $TestResultXmlPath)
    {
        if (-not (Test-Path $xmlPath))
        {
            Write-Warning "Test result file not found: $xmlPath -- treating as failed."
            $overallPassed = $false
            continue
        }

        $anyXmlFound = $true
        [xml]$xml = Get-Content $xmlPath
        $total = [int]$xml.'test-results'.total
        $failures = [int]$xml.'test-results'.failures
        $errors = [int]$xml.'test-results'.errors
        $ignored = [int]$xml.'test-results'.ignored

        Write-Host "Results for '$xmlPath': Total=$total, Failures=$failures, Errors=$errors, Ignored=$ignored"

        if ($failures -gt 0 -or $errors -gt 0 -or $ignored -gt 0)
        {
            $overallPassed = $false
        }
    }

    if (-not $anyXmlFound)
    {
        Write-Warning "No test result files found -- resetting VM with status Failed."
    }
    elseif ($overallPassed)
    {
        $vmStatus = 3   # Passed
    }
    else
    {
        Write-Host "One or more test result files reported failures, errors, or ignored tests."
    }

    Write-Host "==> Resetting Azure session VM '$MachineId' with status $vmStatus ..."
    Reset-AzureSessionVM `
        -ApiBaseUrl  $ApiBaseUrl `
        -AccessToken $accessToken `
        -MachineId   $MachineId `
        -TestStatus  $vmStatus
}

#endregion
