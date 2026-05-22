<#
.SYNOPSIS
    Shared helper functions for TerraForge agent discovery and launch.
#>

function Get-TerraForgeAuthToken
{
    <#
    .SYNOPSIS
        One-stop helper: logs into Azure with a Managed Identity, retrieves the
        TerraForge API access key from Key Vault, and returns a bearer access token.
        Use this instead of calling the three individual functions separately.
    .PARAMETER ManagedIdentityClientId
        The client ID of the Managed Identity (maps to INFRA_MI_CLIENT_ID).
    .PARAMETER KeyVaultName
        The Azure Key Vault name (maps to INFRA_KEYVAULT).
    .PARAMETER ApiKeySecretName
        The Key Vault secret name for the TerraForge API key (maps to TERRAFORGE_API_KEY_SECRET).
    .PARAMETER ApiBaseUrl
        The TerraForge API base URL (maps to TERRAFORGE_API_BASE_URL).
    .OUTPUTS
        [string] The bearer access token, ready to pass as -AccessToken to other functions.
    .EXAMPLE
        $accessToken = Get-TerraForgeAuthToken `
            -ManagedIdentityClientId $env:INFRA_MI_CLIENT_ID `
            -KeyVaultName            $env:INFRA_KEYVAULT `
            -ApiKeySecretName        $env:TERRAFORGE_API_KEY_SECRET `
            -ApiBaseUrl              $env:TERRAFORGE_API_BASE_URL
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ManagedIdentityClientId,

        [Parameter(Mandatory)]
        [string]$KeyVaultName,

        [Parameter(Mandatory)]
        [string]$ApiKeySecretName,

        [Parameter(Mandatory)]
        [string]$ApiBaseUrl
    )

    # Step 1 – Login
    Connect-AzureWithManagedIdentity -ClientId $ManagedIdentityClientId

    # Step 2 – Get API access key from Key Vault
    $apiKey = Get-TerraForgeApiKey -SecretName $ApiKeySecretName -VaultName $KeyVaultName

    # Step 3 – Exchange for bearer token
    return Get-TerraForgeAccessToken -ApiBaseUrl $ApiBaseUrl -ApiAccessKey $apiKey
}

function Connect-AzureWithManagedIdentity
{
    <#
    .SYNOPSIS
        Login to Azure using a Managed Identity.
    .PARAMETER ClientId
        The client ID of the Managed Identity.
    #>
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
    <#
    .SYNOPSIS
        Retrieves the TerraForge API access key from Azure Key Vault.
    .PARAMETER SecretName
        The name of the secret in Key Vault.
    .PARAMETER VaultName
        The name of the Azure Key Vault.
    .OUTPUTS
        [string] The plain-text API access key.
    #>
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
    <#
    .SYNOPSIS
        Requests a TerraForge access token using the provided API access key.
    .PARAMETER ApiBaseUrl
        The base URL of the TerraForge API.
    .PARAMETER ApiAccessKey
        The API access key retrieved from Key Vault.
    .OUTPUTS
        [string] The bearer access token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)]
        [string]$ApiBaseUrl,

        [Parameter(Mandatory)]
        [string]$ApiAccessKey
    )

    $headers = @
    {
        "Content-Type"  = "application/json"
        "X-Client-Type" = "Automated"
    }
    $payload = @
    {
        accessKey = $ApiAccessKey
    } | ConvertTo-Json

    Write-Host "Requesting TerraForge access token..."
    $response = Invoke-WebRequest -Uri "$ApiBaseUrl/api/auth/token" `
        -Method Post -Headers $headers -Body $payload -ErrorAction Stop
    $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

    if (-not ($content -and $content.data -and $content.data.accessToken)) {
        throw "Failed to get access token from response: $($response.Content)"
    }

    return $content.data.accessToken
}

function Invoke-TerraForgeLaunchAgent
{
    <#
    .SYNOPSIS
        Launches/discovers a TerraForge agent machine and returns its details.
    .PARAMETER ApiBaseUrl
        The base URL of the TerraForge API.
    .PARAMETER AccessToken
        The bearer access token from Get-TerraForgeAccessToken.
    .PARAMETER ConfigName
        The TerraForge configuration name to use for the launch.
    .PARAMETER PoolType
        The pool type (default: 3).
    .OUTPUTS
        [PSCustomObject] with MachineId, AgentName, and MachineUrl.
    #>
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

    $authHeaders = @
    {
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
        "X-Client-Type" = "Automated"
    }
    $launchPayload = @
    {
        configName = $ConfigName
        poolType   = $PoolType
    } | ConvertTo-Json

    Write-Host "Sending discover agent request for config: $ConfigName ..."
    $launchResponse = Invoke-WebRequest -Uri "$ApiBaseUrl/api/v1/TestRun/Launch" `
        -Method Post -Headers $authHeaders -Body $launchPayload -ErrorAction Stop
    $launchContent = $launchResponse.Content | ConvertFrom-Json -ErrorAction Stop

    $machineId  = $launchContent.data.machineIds[0]
    $agentName  = "${machineId}_${ConfigName}"
    $machineUrl = "https://terraforge.southeastasia.cloudapp.azure.com/machines/$machineId"

    Write-Host "Launched agent machine: $agentName"
    Write-Host "Machine URL: $machineUrl"

    return [PSCustomObject]@
    {
        MachineId  = $machineId
        AgentName  = $agentName
        MachineUrl = $machineUrl
    }
}

function Set-GitHubOutput
{
    <#
    .SYNOPSIS
        Writes a key-value pair to the GitHub Actions output file.
    .PARAMETER Name
        The output variable name (key).
    .PARAMETER Value
        The output variable value.
    .EXAMPLE
        Set-GitHubOutput -Name 'runner-label' -Value $agentName
        Set-GitHubOutput -Name 'version' -Value '1.0.0'
    #>
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

#region Registry Helpers

function Get-RegistryValue
{
    <#
    .SYNOPSIS
        Reads a value from the Windows registry.
    .PARAMETER Path
        The registry key path. Defaults to the TerraForge agent registry path.
    .PARAMETER Name
        The name of the registry value to read.
    .OUTPUTS
        [object] The registry value, or $null if not found.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter()]
        [string]$Path = 'HKLM:\SOFTWARE\Microsoft\TerraforgeAgent',

        [Parameter()]
        [string]$Name
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $value = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($value) { return $value.$Name } else { return $null }
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

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    if ($Type -eq [Microsoft.Win32.RegistryValueKind]::DWord) {
        if ($Value -is [bool]) {
            $Value = [int]$Value
        } elseif ($Value -in 'True', 'true', '1') {
            $Value = 1
        } elseif ($Value -in 'False', 'false', '0') {
            $Value = 0
        } else {
            try { $Value = [int]$Value }
            catch { throw "Cannot convert value '$Value' to integer for DWord registry type." }
        }
    }

    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Get-SessionID
{
    <#
    .SYNOPSIS
        Reads the TerraForge SessionID from the agent registry.
    .OUTPUTS
        [string] The SessionID value, or $null.
    #>
    [CmdletBinding()]
    param ()
    return Get-RegistryValue -Name 'SessionID'
}

function Get-ConfigName
{
    <#
    .SYNOPSIS
        Reads the TerraForge ConfigName from the agent registry.
    .OUTPUTS
        [string] The ConfigName value, or $null.
    #>
    [CmdletBinding()]
    param ()
    return Get-RegistryValue -Name 'ConfigName'
}

function Get-MachineID
{
    <#
    .SYNOPSIS
        Returns the TerraForge MachineID from the agent registry, falling back to $env:COMPUTERNAME.
    .OUTPUTS
        [string] The MachineID.
    #>
    [CmdletBinding()]
    param ()
    $machineId = Get-RegistryValue -Name 'MachineID'
    if ($machineId) { return $machineId } else { return $env:COMPUTERNAME.ToLower() }}

#endregion

#region VHD Helpers

function Get-VHDDriveLetter
{
    <#
    .SYNOPSIS
        Returns the preferred VHD drive letter (F if available, otherwise C).
    .OUTPUTS
        [string] Single drive letter.
    #>
    [CmdletBinding()]
    param ()
    $drive = Get-PSDrive -Name 'F' -ErrorAction SilentlyContinue
    if ($drive) { return 'F' } else { return 'C' }
}

function Get-VHDDirectoryPath
{
    <#
    .SYNOPSIS
        Returns the full path to the VHD directory on the preferred drive.
    .OUTPUTS
        [string] Path such as 'F:\VHD' or 'C:\VHD'.
    #>
    [CmdletBinding()]
    param ()
    $drive = Get-VHDDriveLetter
    return "${drive}:\VHD"
}

#endregion

#region Azure Key Vault

function Get-AzureKeyVaultSecretValue
{
    <#
    .SYNOPSIS
        Retrieves a secret from Azure Key Vault using a Managed Identity, with retry logic.
    .PARAMETER SecretName
        The name of the secret to retrieve.
    .PARAMETER VaultName
        The Azure Key Vault name.
    .PARAMETER ManagedIdentityClientId
        The client ID of the Managed Identity used to authenticate.
    .PARAMETER AsPlainText
        If specified, returns the secret as plain text inside a hashtable with key 'SecretValue'.
    .PARAMETER RetryCount
        Number of retry attempts on failure (default: 3).
    .OUTPUTS
        Hashtable with key 'SecretValue' (plain text) when -AsPlainText is used,
        otherwise the raw Az secret object.
    #>
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
    while ($attempt -gt 0) {
        try {
            Start-Sleep -Seconds 3

            $ctx = Get-AzContext
            while ($ctx) {
                Write-Verbose "Clearing existing Azure context for account: $($ctx.Account)"
                Disconnect-AzAccount -ErrorAction SilentlyContinue
                Clear-AzContext -Force -ErrorAction SilentlyContinue
                $ctx = Get-AzContext
            }

            Write-Host "Connecting to Azure (ManagedIdentity: $ManagedIdentityClientId)..."
            Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId | Out-Null
            Write-Host "Retrieving secret '$SecretName' from Key Vault '$VaultName'..."

            if ($AsPlainText) {
                $secretValue = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -AsPlainText
                return @
                {
                    SecretValue = $secretValue
                }
            } else {
                $secret = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName
                if (-not $secret.SecretValue) {
                    throw "Secret '$SecretName' returned an empty value."
                }
                return $secret
            }
        } catch {
            $attempt--
            Write-Warning "Failed to retrieve secret (attempts left: $attempt): $($_.Exception.Message)"
            if ($attempt -eq 0) {
                throw "Failed to retrieve secret '$SecretName' after $RetryCount attempts: $($_.Exception.Message)"
            }
        }
    }
}

function Get-SessionAdministratorSecretName
{
    <#
    .SYNOPSIS
        Builds the Key Vault secret name for a session administrator credential.
    .PARAMETER SessionId
        The session ID.
    .PARAMETER MachineId
        The machine ID.
    .PARAMETER Username
        The administrator username (default: Administrator).
    .OUTPUTS
        [string] The secret name in format '{SessionId}-{MachineId}-{Username}'.
    #>
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
    <#
    .SYNOPSIS
        Retrieves the PSCredential for a session administrator from Azure Key Vault.
    .PARAMETER SessionId
        The session ID.
    .PARAMETER MachineId
        The machine ID.
    .PARAMETER VaultName
        The Azure Key Vault name containing user credentials.
    .PARAMETER ManagedIdentityClientId
        The Managed Identity client ID used to access the Key Vault.
    .PARAMETER Username
        The administrator username (default: Administrator).
    .OUTPUTS
        [PSCredential]
    #>
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

#endregion

#region TerraForge VM Lifecycle

function Start-AzureSessionVM
{
    <#
    .SYNOPSIS
        Activates a TerraForge Azure session VM and returns its machine/session details.
    .PARAMETER ApiBaseUrl
        The TerraForge API base URL (e.g. 'https://terraforgeapi.southeastasia.cloudapp.azure.com/api').
    .PARAMETER AccessToken
        The bearer access token from Get-TerraForgeAccessToken.
    .PARAMETER ConfigName
        The TerraForge configuration name (default: 'Catalog-AppRunner').
    .PARAMETER PoolType
        The pool type (default: 2).
    .PARAMETER OsName
        The OS name (default: 'Windows11').
    .PARAMETER Architecture
        The CPU architecture (default: 'X64').
    .PARAMETER AdoBuildId
        Optional ADO build ID to associate with this run.
    .OUTPUTS
        Hashtable with MachineId, SessionId, IPAddress; or $null on 404.
    #>
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

    $headers = @
    {
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRun/Activate"
    $payload = @
    {
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
        $content  = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.data.machineId -or -not $content.data.sessionId) {
            throw "Invalid response received from $uri"
        }

        Write-Host "Started VM — MachineId: $($content.data.machineId), SessionId: $($content.data.sessionId), IP: $($content.data.ipAddress)"
    return @
    {
            MachineId = $content.data.machineId
            SessionId = $content.data.sessionId
            IPAddress = $content.data.ipAddress
        }
    } 
    catch 
    {
        if ($_.Exception.Message -match '404') {
            Write-Warning "Start-AzureSessionVM: resource not found (404). Returning null."
            return $null
        }
        throw "Failed to start Azure session VM: $($_.Exception.Message)"
    }
}

function Reset-AzureSessionVM
{
    <#
    .SYNOPSIS
        Resets a TerraForge Azure session VM.
    .PARAMETER ApiBaseUrl
        The TerraForge API base URL.
    .PARAMETER AccessToken
        The bearer access token.
    .PARAMETER MachineId
        The machine ID to reset.
    .PARAMETER TestStatus
        The test status code to report with the reset.
    #>
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

    $headers = @
    {
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRun/Reset"
    $payload = @
    {
        results = @(
            @
            {
                machineId    = $MachineId
                status       = $TestStatus
                isForceReset = $true
            }
        )
    } | ConvertTo-Json

    try {
        Write-Host "Resetting Azure session VM (MachineId: $MachineId)..."
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content  = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received from $uri"
        }
        Write-Host "Azure session VM '$MachineId' reset successfully."
    } catch {
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

    $headers = @
    {
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/Machines/$MachineId/PowerStatus"

    try {
        Write-Host "Getting power status for VM '$MachineId'..."
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        $content  = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received from $uri"
        }
        Write-Host "VM '$MachineId' status: $($content.data.powerStateFriendlyName)"
        return $content.data.powerStateFriendlyName
    } catch {
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

    $headers = @
    {
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/KeyVault/Secret/TFPFSStorageAccountAccessKey"

    try {
        Write-Host "Retrieving TFPFS storage account access key..."
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        $content  = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received from $uri"
        }
        Write-Host "TFPFS storage account access key retrieved successfully."
        return $content.data.value
    } catch {
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

    $env:AZCOPY_AUTO_LOGIN_TYPE  = 'MSI'
    $env:AZCOPY_MSI_CLIENT_ID    = $ManagedIdentityClientId

    try {
        Write-Host "Starting AzCopy: '$Source' → '$Destination'"
        $result = & azcopy copy $Source $Destination 2>&1
        $result | ForEach-Object { Write-Verbose "AzCopy: $_" }

        if ($LASTEXITCODE -ne 0) {
            throw "AzCopy exited with code $LASTEXITCODE for source: $Source"
        }
        Write-Host "AzCopy completed successfully for '$Source'."
    } catch {
        throw "AzCopy encountered an error: $($_.Exception.Message)"
    }
}

#endregion

#region Test Run Management

function Set-TestRun
{
    <#
    .SYNOPSIS
        Starts or completes a TerraForge test run.
    .PARAMETER ApiBaseUrl
        The TerraForge API base URL.
    .PARAMETER AccessToken
        The bearer access token.
    .PARAMETER Action
        Either 'Start' or 'Complete'.
    .PARAMETER MachineId
        The machine ID (required for Start).
    .PARAMETER ConfigName
        The configuration name (default: 'Catalog-Agent').
    .PARAMETER IsDevOpsAgent
        Whether this is a DevOps agent (default: $true).
    .PARAMETER TestRunId
        The test run ID (required for Complete).
    .PARAMETER AdoBuildId
        Optional ADO build ID.
    .PARAMETER Product
        Product name for the test run.
    .PARAMETER Title
        Title for the test run.
    .PARAMETER QueuedBy
        Who queued the test run.
    .PARAMETER BranchName
        The source branch name.
    .OUTPUTS
        Hashtable with key 'Id' containing the test run ID.
    #>
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
        [string]$BranchName
    )

    $headers = @
    {
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    if ($Action -eq 'Start') {
        $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRun/Start"
    $payload = @
    {
            MachineId = $MachineId
            request   = @
            {
                ConfigName    = $ConfigName
                IsDevOpsAgent = $IsDevOpsAgent
                AdoBuildId    = if ($AdoBuildId) { [int64]$AdoBuildId } else { $null }
                Product       = $Product
                Title         = $Title
                QueuedBy      = $QueuedBy
                BranchName    = $BranchName
            }
        } | ConvertTo-Json -Depth 5
    } else {
        $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRun/Complete"
    $payload = @
    {
            request = @
            {
                Id            = $TestRunId
                IsDevOpsAgent = $IsDevOpsAgent
            }
        } | ConvertTo-Json -Depth 5
    }

    try {
        Write-Host "$Action test run (MachineId: $MachineId)..."
        Write-Host "URI    : $uri"
        Write-Host "Payload: $payload"
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content  = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received from $uri"
        }
        Write-Host "Test run '$Action' succeeded. Id: $($content.data.id)"
        return @
        {
            Id = $content.data.id
        }
    } catch {
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

        [Parameter(Mandatory)]
        [string]$MachineId,

        [Parameter(Mandatory)]
        [string]$TestClass,

        [Parameter()]
        [string]$SessionId,

        [Parameter()]
        [string]$ProductName,

        [Parameter()]
        [string]$TestCaseId = '0'
    )

    $headers = @
    {
        'Authorization' = "Bearer $AccessToken"
        'Content-Type'  = 'application/json'
        'X-Client-Type' = 'Automated'
    }

    $uri = "$($ApiBaseUrl.TrimEnd('/'))/api/v1/TestRunResults/Create"
    $payload = @{
        MachineId      = $MachineId
        SessionId      = $SessionId
        TestRunId      = $TestRunId
        TestCaseId     = $TestCaseId
        Owner          = 'PMPCSH-Test-Team'
        TestClass      = $TestClass
        TestMethod     = $ProductName
        Result         = 3
        StartedTimeUtc = (Get-Date).ToUniversalTime()
        Category       = 'SNAP'
    } | ConvertTo-Json

    try {
        Write-Host "Creating test run result (TestRunId: $TestRunId, MachineId: $MachineId)..."
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content  = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received from $uri"
        }
        Write-Host "Test run result created. Id: $($content.data.id)"
        return @{ Id = $content.data.id }
    } catch {
        throw "Failed to create test run result: $($_.Exception.Message)"
    }
}

function Update-TestRunResults
{
    <#
    .SYNOPSIS
        Updates an existing TerraForge test run result with a final status.
    .PARAMETER ApiBaseUrl
        The TerraForge API base URL.
    .PARAMETER AccessToken
        The bearer access token.
    .PARAMETER TestRunResultId
        The test run result ID to update.
    .PARAMETER Result
        The result status code.
    .PARAMETER ErrorMessage
        Optional error message to record.
    .OUTPUTS
        Hashtable with key 'Id' containing the updated result ID.
    #>
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
    $payload = @
    {
        TestRunResultId = $TestRunResultId
        Result          = $Result
        FinishedTimeUtc = (Get-Date).ToUniversalTime()
        ErrorMessage    = $ErrorMessage
    } | ConvertTo-Json

    try {
        Write-Host "Updating test run result '$TestRunResultId' with result code $Result..."
        $response = Invoke-WebRequest -Uri $uri -Method Patch -Headers $headers -Body $payload -ErrorAction Stop
        $content  = $response.Content | ConvertFrom-Json -ErrorAction Stop

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
