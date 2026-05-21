
function Get-SessionID {
    return Get-RegistryValue -Name "SessionID"
}

function Get-ConfigName {
    return Get-RegistryValue -Name "ConfigName"
}

function Get-MachineID {
    $machine_id = Get-RegistryValue -Name "MachineID"
    if (!$machine_id) {
        $machine_id = $env:COMPUTERNAME.ToLower()
    }
    return $machine_id
}

function Get-RegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = $Global:TerraforgeAgentRegistryPath,

        [Parameter(Mandatory = $false)]
        [string]$Name
    )

    if (!(Test-Path $Path)) {
        return $null
    }

    $value = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue

    if ($value) {
        return $value.$Name
    }

    return $null
}

function Set-RegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Path = $Global:TerraforgeAgentRegistryPath,

        [Parameter(Mandatory = $false)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$Value,

        [Parameter(Mandatory = $false)]
        [Microsoft.Win32.RegistryValueKind]$Type = [Microsoft.Win32.RegistryValueKind]::String
    )

    if (!(Test-Path $Path)) {
        New-Item -Path $Path -Force
    }

    if ($Type -eq 'DWord') {
        # Convert various types to integer for DWord registry values
        if ($Value -is [bool]) {
            $Value = [int]$Value
        }
        elseif ($Value -is [string]) {
            # Handle string representations of boolean values
            if ($Value -eq "True" -or $Value -eq "true" -or $Value -eq "1") {
                $Value = 1
            }
            elseif ($Value -eq "False" -or $Value -eq "false" -or $Value -eq "0") {
                $Value = 0
            }
            else {
                # Try to parse as integer directly
                try {
                    $Value = [int]$Value
                }
                catch {
                    throw "Cannot convert string value '$Value' to integer for DWord registry type"
                }
            }
        }
        else {
            # For other types, try direct conversion to int
            try {
                $Value = [int]$Value
            }
            catch {
                throw "Cannot convert value '$Value' of type $($Value.GetType()) to integer for DWord registry type"
            }
        }
    }

    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Get-VHDDriveLetter {
    $targetDrive = "F"
    $drive = Get-PSDrive -Name $targetDrive -ErrorAction SilentlyContinue
    if (-not $drive) {
        $targetDrive = "C"
    }
    return $targetDrive
}

function Get-VHDDirectoryPath {
    $targetDrive = Get-VHDDriveLetter
    return "${targetDrive}:\VHD"
}

function Get-AzureKeyVaultSecretValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SecretName,
        [Parameter(Mandatory = $false)]
        [string]$VaultName = $Global:UserCredentialsKeyVault,
        [Parameter(Mandatory = $false)]
        [string]$ManagedIdentityClientId = $Global:TestEnvKeyVaultManagedIdentityClientId,
        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText
    )

    if (-not $SecretName) {
        throw "SecretName is required"
    }

    if (-not $VaultName) {
        throw "VaultName is required"
    }

    if (-not $ManagedIdentityClientId) {
        throw "ManagedIdentityClientId is required"
    }

    if ($ManagedIdentityClientId -eq "2d7fbe0d-b3d6-4905-9584-9dc45065865c" -and $SecretName -eq "TerraforgeApiAccessKey") {
        if ($Global:ApiAccessKey) {
            if ($AsPlainText) {
                return @{
                    SecretValue = $Global:ApiAccessKey
                }
            }
            else {
                return $Global:ApiAccessKey
            }
        }
    }

    $reTryCount = 3
    while ($reTryCount -gt 0) {
        try {
            Start-Sleep -Seconds 3
            $currentContext = Get-AzContext
            while ($currentContext) {
                Write-LogFile -Message "Clearing existing Azure context for accountid: $($currentContext.Account)" -MachineID "LocalMachine"
                Disconnect-AzAccount -ErrorAction SilentlyContinue
                Clear-AzContext -Force -ErrorAction SilentlyContinue

                $currentContext = Get-AzContext
            }
            Write-LogFile -Message "Cleared existing Azure context" -MachineID "LocalMachine"
            # Connect to Azure using user assigned managed identity
            Connect-AzAccount -Identity -AccountId $ManagedIdentityClientId
            Write-LogFile -Message "Connected to Azure using Managed Identity ClientId: $ManagedIdentityClientId" -MachineID "LocalMachine"
            Write-LogFile -Message "Getting secret '$SecretName' from keyvault '$VaultName'" -MachineID "LocalMachine"
            if ($AsPlainText) {
                $secretValue = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -AsPlainText
                if ($ManagedIdentityClientId -eq "2d7fbe0d-b3d6-4905-9584-9dc45065865c" -and $SecretName -eq "TerraforgeApiAccessKey") {
                    $Global:ApiAccessKey = $secretValue
                    return @{
                        SecretValue = $secretValue
                    }
                }
                return @{
                    SecretValue = $secretValue
                }
            }
            else {
                $secretValue = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName
                if (-not $secretValue.SecretValue) {
                    throw "Failed to get '$SecretName' secret value from keyvault"
                }
                if ($ManagedIdentityClientId -eq "2d7fbe0d-b3d6-4905-9584-9dc45065865c" -and $SecretName -eq "TerraforgeApiAccessKey") {
                    $Global:ApiAccessKey = $secretValue
                    return $secretValue
                }
                return $secretValue
            }
        }
        catch {
            $reTryCount--
            if ($reTryCount -eq 0) {
                throw "Failed to get Azure context after multiple attempts"
            }
        }
    }
}

function Get-SessionAdministratorSecretName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [int]$SessionId,
        [Parameter(Mandatory = $false)]
        [string]$MachineId,
        [Parameter(Mandatory = $false)]
        [string]$Username = "Administrator"
    )

    if (-not $SessionId -or -not $MachineId) {
        return $null
    }
    Write-LogFile -Message "SecretName: $SessionId-$MachineId-$Username" -MachineID $MachineId
    return "$SessionId-$MachineId-$Username"
}

function Get-SessionAdministratorCredential {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [int]$SessionId,
        [Parameter(Mandatory = $false)]
        [string]$MachineId,
        [Parameter(Mandatory = $false)]
        [string]$Username = "Administrator"
    )
    $secretName = Get-SessionAdministratorSecretName -SessionId $SessionId -MachineId $MachineId -Username $Username
    if (-not $secretName) {
        throw "SessionId and MachineId are required to get session administrator credential"
    }
    Write-LogFile -Message "Get value from $($Global:UserCredentialsKeyVault) using $secretName" -MachineID $MachineId
    Write-LogFile -Message "ManagedIdentityClientId: $($Global:TestEnvKeyVaultManagedIdentityClientId)" -MachineID $MachineId
    $secret = Get-AzureKeyVaultSecretValue -SecretName $secretName -VaultName $Global:UserCredentialsKeyVault -ManagedIdentityClientId $Global:TestEnvKeyVaultManagedIdentityClientId -AsPlainText
    $adminPassword = $secret.SecretValue
    $SecureString = ConvertTo-SecureString -AsPlainText -Force -String $adminPassword
    $VMCredentialAdmin = [System.Management.Automation.PSCredential]::new($Username, $SecureString)

    return $VMCredentialAdmin
}

function Get-TerraforgeApiAccessToken {
    [CmdletBinding()]
    param()
    Write-LogFile -Message "Get Terraforge API access token using secret from $($Global:InfraManagementKeyVault) using $($Global:InfraKeyVaultManagedIdentityClientId)" -MachineID "LocalMachine"
    if ($Global:ApiAccessKey) {
        # Write-LogFile -Message "Get '$Global:TerraforgeApiAccessKeySecretName' from Key Vault: $($Global:InfraManagementKeyVault)" -MachineID "LocalMachine"
        # $secret = Get-AzureKeyVaultSecretValue -SecretName "TerraforgeApiAccessKey" -VaultName "kv-tfp-infra-management" -ManagedIdentityClientId "2d7fbe0d-b3d6-4905-9584-9dc45065865c" -AsPlainText
        # $terraforgeApiAccessValue = $secret.SecretValue
        Write-LogFile -Message "Using global Terraforge API access key successful" -MachineID "LocalMachine"
        Write-PSFMessage "Using global Terraforge API access key successful"
        $terraforgeApiAccessValue = $Global:ApiAccessKey
    }
    else {
        Write-PSFMessage "Failed to retrieve global Terraforge API access key"
        Write-LogFile -Message "Failed to retrieve global Terraforge API access key" -MachineID "LocalMachine"
        throw "Failed to retrieve global Terraforge API access key"
    }
    Write-LogFile -Message "Retrieved Terraforge API access key from Key Vault" -MachineID "LocalMachine"
    $getTokenUri = "$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/auth/token"
    $headers = @{
        'X-Client-Type' = "Automated"
    }
    $payload = @{
        accessKey = $terraforgeApiAccessValue
    } | ConvertTo-Json
    Write-LogFile -Message "Get-TerraforgeApiAccessToken Uri: $getTokenUri" -MachineID "LocalMachine"
    $response = Invoke-WebRequest -Uri $getTokenUri -Method Post -ContentType "application/json" -Headers $headers -Body $payload -ErrorAction Stop
    $content = $response.Content | ConvertFrom-Json -ErrorAction Stop
    if ($content -and $content.data -and $content.data.accessToken) {
        Write-LogFile -Message "Successfully retrieved access token from Terraforge API." -MachineID "LocalMachine"
        $accessToken = $content.data.accessToken
        return $accessToken
    }
    else {
        Write-PSFMessage "Failed to retrieve access token from Terraforge API."
        Write-LogFile -Message "Failed to retrieve access token from Terraforge API." -MachineID "LocalMachine"
        throw "Failed to retrieve access token from Terraforge API."
    }
}

function Start-AzureSessionVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ConfigName = "Catalog-AppRunner",
        [Parameter(Mandatory = $false)]
        [int]$PoolType = 2,
        [Parameter(Mandatory = $false)]
        [string]$osName = "Windows11",
        [Parameter(Mandatory = $false)]
        [string]$architecture = "X64",
        [Parameter(Mandatory = $false)]
        [string]$AdoBuildId
    )

    $accessToken = Get-TerraforgeApiAccessToken

    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = "application/json"
        'X-Client-Type' = "Automated"
    }

    $uri = "$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/v1/TestRun/Activate"

    $payload = @{
        configName   = $ConfigName
        poolType     = $PoolType
        osName       = $osName
        architecture = $architecture
        AdoBuildId   = $AdoBuildId
    } | ConvertTo-Json

    try {
        Write-LogFile -Message "Start-AzureSessionVM Uri: $uri"
        Write-LogFile -Message "Payload: $payload"
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop

        if (-not $content -or -not $content.data -or -not $content.data.machineId -or -not $content.data.sessionId) {
            throw "Invalid response received."
        }
        Write-PSFMessage "Started Azure session VM with MachineId: $($content.data.machineId), SessionId: $($content.data.sessionId), IPAddress: $($content.data.ipAddress)"
        Write-LogFile -Message "Started Azure session VM with MachineId: $($content.data.machineId), SessionId: $($content.data.sessionId), IPAddress: $($content.data.ipAddress)"
        return @{
            MachineId = $content.data.machineId
            SessionId = $content.data.sessionId
            IPAddress = $content.data.ipAddress
        }
    }
    catch {
        Write-LogFile -Message "Failed to start Azure session VM: $($_.Exception.Message)"
        if (-not ($_.Exception.Message -contains "404")) {
            throw "Failed to start Azure session VM: $($_.Exception.Message)"
        }
        else {
            return $null
        }
    }
}

function Reset-AzureSessionVM {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineId,
        [Parameter(Mandatory = $false)]
        [int]$TestStatus
    )

    $accessToken = Get-TerraforgeApiAccessToken

    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = "application/json"
        'X-Client-Type' = "Automated"
    }

    $uri = "$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/v1/TestRun/Reset"

    $payload = @{
        results = @(
            @{
                machineId    = $MachineId
                status       = $TestStatus
                isForceReset = $true
            }
        )
    } | ConvertTo-Json

    try {
        Write-LogFile -Message "Reset-AzureSessionVM Uri: $uri" -MachineID $MachineId
        Write-LogFile -Message "Payload: $payload" -MachineID $MachineId
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop
        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received."
        }
        Write-LogFile -Message "Azure session VM with MachineId: $MachineId has been reset successfully." -MachineID $MachineId
        Write-PSFMessage "Azure session VM with MachineId: $MachineId has been reset successfully."
    }
    catch {
        Write-LogFile -Message "Failed to reset Azure session VM: $($_.Exception.Message)" -MachineID $MachineId
        throw "Failed to reset Azure session VM: $($_.Exception.Message)"
    }
}

function Get-AzureVMStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineId
    )

    $accessToken = Get-TerraforgeApiAccessToken

    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = "application/json"
        'X-Client-Type' = "Automated"
    }

    $uri = "$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/v1/Machines/$MachineId/PowerStatus"

    try {
        Write-LogFile -Message "Check-AzureVMStatus Uri: $uri" -MachineID $MachineId
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop
        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received."
        }
        Write-LogFile -Message "Azure VM Status: $($content.data.powerStateFriendlyName)" -MachineID $MachineId
        Write-PSFMessage "Azure VM Status: $($content.data.powerStateFriendlyName)"
        return ($content.data.powerStateFriendlyName)
    }
    catch {
        Write-LogFile -Message "Get-AzureVMStatus failed: $($_.Exception.Message)" -MachineID $MachineId
        throw "Get Azure VM status failed: $($_.Exception.Message)"
    }
}
function Get-TFPFSStorageAccountAccessKey {

    $accessToken = Get-TerraforgeApiAccessToken

    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = "application/json"
        'X-Client-Type' = "Automated"
    }

    $uri = "$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/v1/KeyVault/Secret/TFPFSStorageAccountAccessKey"

    try {
        Write-LogFile -Message "Get-TFPFSStorageAccountAccessKey Uri: $uri" -MachineID "LocalMachine"
        $response = Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop
        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received."
        }
        Write-LogFile -Message "TFPFS Storage Account Access Key successfully retrieved." -MachineID "LocalMachine"
        return ($content.data.value)
    }
    catch {
        Write-LogFile -Message "Get-TFPFSStorageAccountAccessKey failed: $($_.Exception.Message)" -MachineID "LocalMachine"
        throw "Get TFPFS Storage Account Access Key failed: $($_.Exception.Message)"
    }
}
function Set-TestRun {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $false)]
        [string]$MachineId,
        [Parameter(Mandatory = $false)]
        [string]$ConfigName = "Catalog-Agent",
        [Parameter(Mandatory = $false)]
        [bool]$IsDevOpsAgent = $true,
        [Parameter(Mandatory = $false)]
        [string]$TestRunId,
        [Parameter(Mandatory = $false)]
        [string]$AdoBuildId,
        [Parameter(Mandatory = $false)]
        [string]$Product,
        [Parameter(Mandatory = $false)]
        [string]$Title,
        [Parameter(Mandatory = $false)]
        [string]$QueuedBy,
        [Parameter(Mandatory = $false)]
        [string]$BranchName
    )

    $accessToken = Get-TerraforgeApiAccessToken

    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = "application/json"
        'X-Client-Type' = "Automated"
    }

    if ($Action -eq "Start") {
        $uri = "$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/v1/TestRun/Start"
        $payload = @{
            MachineId     = $MachineId
            ConfigName    = $ConfigName
            IsDevOpsAgent = $IsDevOpsAgent
            AdoBuildId    = $AdoBuildId
            Product       = $Product
            Title         = $Title
            QueuedBy      = $QueuedBy
            BranchName    = $BranchName
        } | ConvertTo-Json
    }
    if ($Action -eq "Complete") {
        $uri = "$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/v1/TestRun/Complete"
        $payload = @{
            Id            = $TestRunId
            IsDevOpsAgent = $IsDevOpsAgent
        } | ConvertTo-Json
    }
    
    try {
        Write-LogFile -Message "Set-TestRun Uri: $uri" -MachineID "LocalMachine"
        Write-LogFile -Message "Payload: $payload" -MachineID "LocalMachine"
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop
        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received."
        }
        if ($Action -eq "Start") {
            Write-LogFile -Message "TestRunId: $($content.data.id)" -MachineID "LocalMachine"
            Write-PSFMessage "Test run started successfully for MachineId: $env:COMPUTERNAME, TestRunId: $($content.data.id)"
        }
        if ($Action -eq "Complete") {
            Write-LogFile -Message "Test run completed successfully for MachineId: $env:COMPUTERNAME" -MachineID "LocalMachine"
            Write-PSFMessage "Test run completed successfully for MachineId: $env:COMPUTERNAME"
        }
        return @{
            Id = $content.data.id
        }
    }
    catch {
        Write-LogFile -Message "Failed to $Action test run: $($_.Exception.Message)" -MachineID $MachineId
        throw "Failed to $Action test run: $($_.Exception.Message)"
    }
}

function New-TestRunResults {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TestRunId,
        [Parameter(Mandatory = $true)]
        [string]$MachineId,
        [Parameter(Mandatory = $true)]
        [string]$TestClass,
        [Parameter(Mandatory = $false)]
        [string]$SessionId,
        [Parameter(Mandatory = $false)]
        [string]$ProductName,
        [Parameter(Mandatory = $false)]
        [string]$TestCaseId = 0

    )

    $accessToken = Get-TerraforgeApiAccessToken

    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = "application/json"
        'X-Client-Type' = "Automated"
    }

    $uri = "$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/v1/TestRunResults/Create"

    $payload = @{
        MachineId      = $MachineId
        SessionId      = $SessionId
        TestRunId      = $TestRunId
        TestCaseId     = $TestCaseId
        Owner          = "PMPCSH-Test-Team"
        TestClass      = $TestClass
        TestMethod     = $ProductName
        Result         = 3
        StartedTimeUtc = (Get-Date -AsUTC)
        Category       = "SNAP"
    } | ConvertTo-Json

    try {
        Write-LogFile -Message "New-TestRunResults Uri: $uri, Method: Post" -MachineID "LocalMachine"
        Write-LogFile -Message "Payload: $payload" -MachineID "LocalMachine"
        $response = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop
        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received."
        }
        Write-LogFile -Message "Test run result $($content.data.id) created successfully for MachineId: $MachineId" -MachineID "LocalMachine"
        Write-PSFMessage "Test run result created successfully for MachineId: $MachineId"
        return @{
            Id = $content.data.id
        }
    }
    catch {
        Write-LogFile -Message "Failed to create test run result: $($_.Exception.Message)" -MachineID "LocalMachine"
        throw "Failed to create test run result: $($_.Exception.Message)"
    }
}

function Update-TestRunResults {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TestRunResultId,
        [Parameter(Mandatory = $true)]
        [int]$Result,
        [Parameter(Mandatory = $false)]
        [string]$ErrorMessage

    )

    $accessToken = Get-TerraforgeApiAccessToken

    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = "application/json"
        'X-Client-Type' = "Automated"
    }

    $uri = ("$($Global:TerraforgeApiBaseUrl.TrimEnd('/'))/v1/TestRunResults/Update/{0}" -f $TestRunResultId)

    $payload = @{
        TestRunResultId = $TestRunResultId
        Result          = $Result
        FinishedTimeUtc = (Get-Date -AsUTC)
        ErrorMessage    = $ErrorMessage
    } | ConvertTo-Json

    try {
        Write-LogFile -Message "Update-TestRunResults Uri: $uri" -MachineID "LocalMachine"
        Write-LogFile -Message "Payload: $payload" -MachineID "LocalMachine"
        $response = Invoke-WebRequest -Uri $uri -Method Patch -Headers $headers -Body $payload -ErrorAction Stop
        $content = $response.Content | ConvertFrom-Json -ErrorAction Stop
        if (-not $content -or -not $content.data -or -not $content.success) {
            throw "Invalid response received."
        }
        Write-LogFile -Message "Test run result updated successfully for MachineId: $($env:COMPUTERNAME)" -MachineID "LocalMachine"
        Write-PSFMessage "Test run result updated successfully for MachineId: $($env:COMPUTERNAME)"
        return @{
            Id = $content.data.id
        }
    }
    catch {
        Write-LogFile -Message "Failed to update test run result: $($_.Exception.Message)" -MachineID "LocalMachine"
        throw "Failed to update test run result: $($_.Exception.Message)"
    }
}

function Write-LogFile {
    param (
        [string]$Message,
        [string]$MachineID = 'StartAzureSessionVM'
    )
    try {
        $logFolder = "C:\DevopsPipelineCatalogLogs"
        if (-not (Test-Path $logFolder)) {
            New-Item -Path $logFolder -ItemType Directory -Force | Out-Null
        }
        $logPath = "$logFolder\Log_$MachineID.log"
        $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $LogEntry = "[$Timestamp] $Message"
        $LogEntry | Out-File -FilePath $logPath -Append -Encoding UTF8
    }
    catch {
        
    }
}

function Start-AzCopy {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,
    
        [Parameter(Mandatory = $true)]
        [string]$Destination,
    
        [Parameter(Mandatory = $true)]
        [string]$CLIENT_ID
    )
    $env:AZCOPY_AUTO_LOGIN_TYPE = "MSI"
    $env:AZCOPY_MSI_CLIENT_ID = $CLIENT_ID

    try {
        Write-PSFMessage "Starting AzCopy from $Source to $Destination"
        $azcopyResult = & azcopy copy $Source $Destination 2>&1
        if ($azcopyResult) {
            foreach ($line in $azcopyResult) {
                Write-LogFile "AzCopy: $line" -MachineID "UploadingToStorage"
                Write-PSFMessage "AzCopy: $line"
                Write-LogFile -Message "AzCopy: $line" -MachineID "LocalMachine"
            }
        }

        # Check if azcopy succeeded for this file
        if ($LASTEXITCODE -ne 0) {
            Write-PSFMessage "AzCopy transfer failed for $Source with exit code: $LASTEXITCODE"
            Write-LogFile -Message "AzCopy transfer failed for $Source with exit code: $LASTEXITCODE" -MachineID "LocalMachine"
        }
        else {
            Write-PSFMessage "AzCopy transfer completed successfully for $Source!"
            Write-LogFile -Message "AzCopy transfer completed successfully for $Source!" -MachineID "LocalMachine"
        }
    }
    catch {
        Write-PSFMessage "AzCopy encountered an error: $($_.Exception.Message)"
        Write-LogFile -Message "AzCopy encountered an error: $($_.Exception.Message)" -MachineID "LocalMachine"
    }
}

Export-ModuleMember -Function 'Get-SessionID',
'Get-ConfigName',
'Get-MachineID',
'Get-RegistryValue',
'Set-RegistryValue',
'Get-VHDDriveLetter',
'Get-VHDDirectoryPath',
'Get-AzureKeyVaultSecretValue',
'Get-SessionAdministratorSecretName',
'Get-SessionAdministratorCredential',
'Get-TerraforgeApiAccessToken',
'Start-AzureSessionVM',
'Reset-AzureSessionVM',
'Get-AzureVMStatus',
'Write-LogFile',
'Set-TestRun',
'New-TestRunResults',
'Update-TestRunResults',
'Get-TFPFSStorageAccountAccessKey',
'Start-AzCopy'