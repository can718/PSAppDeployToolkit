function script:Invoke-WinSCPSccmClientEvaluation
{
    Write-Information "Triggering policy/application/update evaluation" -InformationAction Continue

    # Computer policy
    $trigger = "{00000000-0000-0000-0000-000000000021}"
    [void]([wmiclass]"\\.\root\ccm:SMS_Client").TriggerSchedule($trigger)

    # Application evaluation
    $trigger = "{00000000-0000-0000-0000-000000000121}"
    [void]([wmiclass]"\\.\root\ccm:SMS_Client").TriggerSchedule($trigger)

    # Send unsent state message (report deployment state back to site)
    $trigger = "{00000000-0000-0000-0000-000000000111}"
    [void]([wmiclass]"\\.\root\ccm:SMS_Client").TriggerSchedule($trigger)
}

$sharedLogValidationPath = Join-Path $PSScriptRoot '..\_Shared\Invoke-PSADTLogValidation.ps1'
if (-not (Test-Path -LiteralPath $sharedLogValidationPath -PathType Leaf))
{
    throw "Required shared helper file not found: $sharedLogValidationPath"
}
. $sharedLogValidationPath

function script:Invoke-WinSCPPollDeploymentStatus
{
    <#
        Polls SMS_DeploymentSummary until at least one device reports success
        or the timeout is reached.
        Returns the final SMS_DeploymentSummary CIM instance (or $null).
    #>
    param (
        [string]$AppName,
        [string]$SiteCode,
        [string]$Label = 'Deployment',
        [int]$MaxWaitSeconds = 1800,
        [int]$PollInterval = 300
    )

    $elapsed = 0
    $summary = $null
    $cimNamespace = "root\SMS\Site_$SiteCode"

    $queryMaxAttempts = 4
    $queryDelaySeconds = 15
    $envQueryMaxAttempts = 0
    if ([int]::TryParse([string]$env:PSADT_SCCM_QUERY_MAX_ATTEMPTS, [ref]$envQueryMaxAttempts) -and $envQueryMaxAttempts -ge 1)
    {
        $queryMaxAttempts = $envQueryMaxAttempts
    }

    $envQueryDelaySeconds = 0
    if ([int]::TryParse([string]$env:PSADT_SCCM_QUERY_DELAY_SECONDS, [ref]$envQueryDelaySeconds) -and $envQueryDelaySeconds -ge 1)
    {
        $queryDelaySeconds = $envQueryDelaySeconds
    }

    function Invoke-SCCMQueryWithRetry
    {
        param(
            [Parameter(Mandatory = $true)]
            [scriptblock]$ScriptBlock,
            [Parameter(Mandatory = $true)]
            [string]$OperationName,
            [switch]$SuppressFinalThrow
        )

        for ($attempt = 1; $attempt -le $queryMaxAttempts; $attempt++)
        {
            try
            {
                return (& $ScriptBlock)
            }
            catch
            {
                $exception = $_.Exception
                $errorMessage = $exception.Message
                $innerMessage = if ($exception.InnerException) { $exception.InnerException.Message } else { '' }
                $hResultHex = ('0x{0:X8}' -f ($exception.HResult -band 0xFFFFFFFF))
                $isTransientConnectivityError = $errorMessage -match 'SMS Provider reported an error|RPC server is unavailable|The network path was not found|The server is unavailable|timed out|timeout|WinRM|Cannot connect|connection.*failed|provider.*not available|Generic failure'

                Write-Warning ("[SCCM] {0} failed on attempt {1}/{2}. HResult={3}, Message='{4}', Inner='{5}'" -f $OperationName, $attempt, $queryMaxAttempts, $hResultHex, $errorMessage, $innerMessage)

                if (-not $isTransientConnectivityError)
                {
                    if ($SuppressFinalThrow)
                    {
                        return $null
                    }
                    throw
                }

                if ($attempt -ge $queryMaxAttempts)
                {
                    if ($SuppressFinalThrow)
                    {
                        Write-Warning ("[SCCM] {0} exhausted retry attempts ({1}). Continuing with null result." -f $OperationName, $queryMaxAttempts)
                        return $null
                    }
                    throw
                }

                Write-Information ("[SCCM] Transient failure in {0}. Retrying in {1} second(s)..." -f $OperationName, $queryDelaySeconds) -InformationAction Continue
                Start-Sleep -Seconds $queryDelaySeconds
            }
        }

        return $null
    }

    do
    {
        $deployments = Invoke-SCCMQueryWithRetry -OperationName ("Get-CMDeployment for '{0}'" -f $AppName) -SuppressFinalThrow -ScriptBlock {
            Get-CMDeployment -SoftwareName $AppName -ErrorAction Stop
        }

        $deployments | ForEach-Object {
            $deploymentId = $_.DeploymentId
            [void](Invoke-SCCMQueryWithRetry -OperationName ("Invoke-CMDeploymentSummarization for DeploymentId '{0}'" -f $deploymentId) -SuppressFinalThrow -ScriptBlock {
                    Invoke-CMDeploymentSummarization -DeploymentId $deploymentId -ErrorAction Stop
                })
        }

        $summary = $null
        if (-not [string]::IsNullOrWhiteSpace($SiteCode))
        {
            $summary = Invoke-SCCMQueryWithRetry -OperationName ("Get-CimInstance SMS_DeploymentSummary in '{0}' for '{1}'" -f $cimNamespace, $AppName) -SuppressFinalThrow -ScriptBlock {
                Get-CimInstance -Namespace $cimNamespace -ClassName SMS_DeploymentSummary -ErrorAction Stop |
                    Where-Object { $_.ApplicationName -eq $AppName } |
                    Select-Object -First 1
            }
        }

        if ($summary)
        {
            Write-Information "[$AppName] $Label status (elapsed ${elapsed}s): Success=$($summary.NumberSuccess) InProgress=$($summary.NumberInProgress) Error=$($summary.NumberErrors) Targeted=$($summary.NumberTargeted)" -InformationAction Continue
            if ($summary.NumberSuccess -gt 0)
            {
                break
            }
        }

        if ($elapsed -lt $MaxWaitSeconds)
        {
            Write-Information "[$AppName] $Label not yet successful - waiting ${PollInterval}s before next check..." -InformationAction Continue
            Invoke-WinSCPSccmClientEvaluation | Out-Null
            Start-Sleep -Seconds $PollInterval
            $elapsed += $PollInterval
        }
        else
        {
            break
        }
    }
    while ($elapsed -le $MaxWaitSeconds)

    # Final authoritative read - only if the loop did not already capture a result
    if (-not $summary -and -not [string]::IsNullOrWhiteSpace($SiteCode))
    {
        $summary = Invoke-SCCMQueryWithRetry -OperationName ("Final Get-CimInstance SMS_DeploymentSummary in '{0}' for '{1}'" -f $cimNamespace, $AppName) -SuppressFinalThrow -ScriptBlock {
            Get-CimInstance -Namespace $cimNamespace -ClassName SMS_DeploymentSummary -ErrorAction Stop |
            Where-Object { $_.ApplicationName -eq $AppName } |
            Select-Object -First 1
        }
    }
    return $summary
}

function script:Test-PSADTTemplateValidationGate
{
    <#
        Allows SCCM package tests to run only after template validation.
        Gate can be satisfied by:
        1) Current test run has already passed validation, or
        2) Pipeline sets PSADT_TEMPLATE_VALIDATION_PASSED=true
    #>
    if ($script:TemplateValidationPassed)
    {
        return $true
    }

    $gateFromEnv = $env:PSADT_TEMPLATE_VALIDATION_PASSED
    return @('1', 'true', 'yes', 'passed') -contains "$gateFromEnv".ToLowerInvariant()
}

function script:Remove-DirectoryWithRetry
{
    <#
        Removes a directory tree with retry to handle transient file locks in CI.
        Falls back to cmd rmdir for stubborn cases where Remove-Item can fail on Windows.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$MaxAttempts = 4,
        [int]$DelaySeconds = 2
    )

    if (-not (Test-Path -LiteralPath $Path))
    {
        return
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++)
    {
        try
        {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $Path))
            {
                return
            }
        }
        catch
        {
            $lastError = $_
        }

        # Fallback for stubborn directory trees on Windows CI agents.
        try
        {
            cmd.exe /c "rmdir /s /q \"$Path\"" | Out-Null
            if (-not (Test-Path -LiteralPath $Path))
            {
                return
            }
        }
        catch
        {
            $lastError = $_
        }

        if ($attempt -lt $MaxAttempts)
        {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $msg = if ($lastError) { $lastError.Exception.Message } else { 'Unknown error while removing directory.' }
    throw "Failed to remove directory '$Path' after $MaxAttempts attempts. Last error: $msg"
}

function script:Test-PSADTPackageBuildPrerequisites
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$TemplateDir,
        [Parameter(Mandatory = $true)]
        [string]$TemplateEnvName,
        [Parameter(Mandatory = $true)]
        [string]$SiteCode,
        [Parameter(Mandatory = $true)]
        [string]$SiteServer,
        # [Parameter(Mandatory = $true)]
        # [string]$SourceScript,
        [Parameter(Mandatory = $true)]
        [string]$SourceScriptLabel,
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [switch]$UseInformationLogs
    )

    if (-not $TemplateDir)
    {
        Set-ItResult -Skipped -Because "$TemplateEnvName not set"
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($SiteCode) -or [string]::IsNullOrWhiteSpace($SiteServer))
    {
        Set-ItResult -Skipped -Because 'SCCM siteCode or siteServer not configured (not an SCCM-managed environment)'
        return $false
    }

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Step 1: Verifying prerequisites..." -InformationAction Continue
    }
    else
    {
        Write-Verbose "[$LogPrefix] Step 1: Verifying prerequisites..."
    }

    Test-Path $TemplateDir | Should -BeTrue -Because "V4 template directory '$TemplateDir' must exist"

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] V4 template directory '$TemplateDir' verified." -InformationAction Continue
        Write-Information "::info::[$LogPrefix] $SourceScriptLabel verified." -InformationAction Continue
    }

    return $true
}

function script:Initialize-PSADTPackageDirectoryFromTemplate
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$TemplateDir,
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [switch]$UseInformationLogs
    )

    $resolvedPackageRoot = $null
    function Resolve-PSADTPackageRoot
    {
        param (
            [Parameter(Mandatory = $true)]
            [string]$RootPath
        )

        if (Test-Path -LiteralPath (Join-Path $RootPath 'Invoke-AppDeployToolkit.ps1') -PathType Leaf)
        {
            return $RootPath
        }

        $nestedRoot = Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Invoke-AppDeployToolkit.ps1') -PathType Leaf } | Select-Object -First 1 -ExpandProperty FullName

        if (-not [string]::IsNullOrWhiteSpace($nestedRoot))
        {
            return $nestedRoot
        }

        return $RootPath
    }

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Step 2: Copying V4 template to package directory..." -InformationAction Continue
    }
    else
    {
        Write-Verbose "[$LogPrefix] Step 2: Copying V4 template to package directory..."
    }

    if (Test-Path $PackageDir)
    {
        if ($UseInformationLogs)
        {
            Write-Information "::warning::[$LogPrefix] Package directory '$PackageDir' already exists, removing it." -InformationAction Continue
        }
        Remove-DirectoryWithRetry -Path $PackageDir
        if ($UseInformationLogs)
        {
            Write-Information "::info::[$LogPrefix] Package directory '$PackageDir' removed." -InformationAction Continue
        }
    }

    New-Item -Path $PackageDir -ItemType Directory -Force | Out-Null
    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Package directory '$PackageDir' created." -InformationAction Continue
    }

    Copy-Item -Path "$TemplateDir\*" -Destination $PackageDir -Recurse -Force

    $resolvedPackageRoot = Resolve-PSADTPackageRoot -RootPath $PackageDir

    $recordingModuleSource = Join-Path $PSScriptRoot '..\_Shared\PSAppDeployToolkit.Recording.psm1'
    if (Test-Path -LiteralPath $recordingModuleSource -PathType Leaf)
    {
        $recordingDir = Join-Path $resolvedPackageRoot 'PSAppDeployToolkit.Recording'
        if (-not (Test-Path -LiteralPath $recordingDir -PathType Container))
        {
            New-Item -Path $recordingDir -ItemType Directory -Force | Out-Null
        }

        $recordingModuleDestination = Join-Path $recordingDir 'PSAppDeployToolkit.Recording.psm1'
        Copy-Item -Path $recordingModuleSource -Destination $recordingModuleDestination -Force

        if ($UseInformationLogs)
        {
            Write-Information "::info::[$LogPrefix] Injected recording extension module: $recordingModuleDestination" -InformationAction Continue
        }
        else
        {
            Write-Verbose "[$LogPrefix] Injected recording extension module: $recordingModuleDestination"
        }
    }
    else
    {
        Write-Warning "[$LogPrefix] Recording extension module source not found: $recordingModuleSource"
    }

    Test-Path $PackageDir | Should -BeTrue
}

function script:Initialize-PSADTPackageDirectoryFromTemplateV4
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$TemplateDir,
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [switch]$UseInformationLogs
    )

    $resolvedPackageRoot = $null
    function Resolve-PSADTPackageRoot
    {
        param (
            [Parameter(Mandatory = $true)]
            [string]$RootPath
        )

        if (Test-Path -LiteralPath (Join-Path $RootPath 'Invoke-AppDeployToolkit.ps1') -PathType Leaf)
        {
            return $RootPath
        }

        $nestedRoot = Get-ChildItem -Path $RootPath -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Invoke-AppDeployToolkit.ps1') -PathType Leaf } | Select-Object -First 1 -ExpandProperty FullName

        if (-not [string]::IsNullOrWhiteSpace($nestedRoot))
        {
            return $nestedRoot
        }

        return $RootPath
    }

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Step 2: Generating V4 package via Invoke-ADTTemplateRunner..." -InformationAction Continue
    }
    else
    {
        Write-Verbose "[$LogPrefix] Step 2: Generating V4 package via Invoke-ADTTemplateRunner..."
    }

    if (Test-Path $PackageDir)
    {
        if ($UseInformationLogs)
        {
            Write-Information "::warning::[$LogPrefix] Package directory '$PackageDir' already exists, removing it." -InformationAction Continue
        }
        Remove-DirectoryWithRetry -Path $PackageDir
        if ($UseInformationLogs)
        {
            Write-Information "::info::[$LogPrefix] Package directory '$PackageDir' removed." -InformationAction Continue
        }
    }

    $templateRunnerPath = Join-Path $PSScriptRoot '..\_Shared\Invoke-ADTTemplateRunner.ps1'
    $templateParamsPath = Join-Path $PSScriptRoot ("..\V4\$LogPrefix\New-ADTTemplate.params.ps1")

    if (-not (Test-Path -LiteralPath $templateRunnerPath -PathType Leaf))
    {
        throw "Invoke-ADTTemplateRunner file not found: $templateRunnerPath"
    }
    if (-not (Test-Path -LiteralPath $templateParamsPath -PathType Leaf))
    {
        throw "Template parameter file not found for [$LogPrefix]: $templateParamsPath"
    }

    $psadtManifestPath = Get-ChildItem -Path $TemplateDir -Filter 'PSAppDeployToolkit.psd1' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($psadtManifestPath))
    {
        throw "Unable to find PSAppDeployToolkit.psd1 under TemplateDir: $TemplateDir"
    }

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Importing PSADT module manifest: $psadtManifestPath" -InformationAction Continue
    }
    else
    {
        Write-Verbose "[$LogPrefix] Importing PSADT module manifest: $psadtManifestPath"
    }
    Import-Module -FullyQualifiedName $psadtManifestPath -Force -ErrorAction Stop

    . $templateRunnerPath
    . $templateParamsPath

    if (-not (Get-Variable -Name NewADTTemplateParameters -Scope Local -ErrorAction Ignore))
    {
        throw "Variable `$NewADTTemplateParameters was not found after loading [$templateParamsPath]."
    }

    $templateParams = (Get-Variable -Name NewADTTemplateParameters -Scope Local).Value
    if ($null -eq $templateParams -or $templateParams -isnot [System.Collections.IDictionary])
    {
        throw "Variable `$NewADTTemplateParameters in [$templateParamsPath] is not a hashtable/dictionary."
    }

    $filesValue = $templateParams['Files']
    if ($null -eq $filesValue)
    {
        throw "Template parameter file [$templateParamsPath] does not define a non-null [Files] value."
    }

    $filesList = [System.Collections.Generic.List[System.String]]::new()
    foreach ($filePath in @($filesValue))
    {
        if (-not [System.String]::IsNullOrWhiteSpace([string]$filePath))
        {
            $filesList.Add([string]$filePath)
        }
    }

    if ($filesList.Count -eq 0)
    {
        throw "Template parameter file [$templateParamsPath] did not resolve any valid [Files] entries."
    }
    $packageDirName = Split-Path -Path $PackageDir -Leaf
    $packageDirParent = Split-Path -Path $PackageDir -Parent

    if ([string]::IsNullOrWhiteSpace($packageDirName) -or [string]::IsNullOrWhiteSpace($packageDirParent))
    {
        throw "Invalid PackageDir path: $PackageDir"
    }

    if (-not (Test-Path -LiteralPath $packageDirParent -PathType Container))
    {
        New-Item -Path $packageDirParent -ItemType Directory -Force | Out-Null
    }

    $invokeTemplateParams = @{
        TemplatefilePath = $templateParamsPath
        DestinationPath  = $packageDirParent
        Name             = $packageDirName
        Files            = $filesList
    }

    if ($templateParams.Contains('SupportFiles') -and $null -ne $templateParams['SupportFiles'])
    {
        $supportFilesList = [System.Collections.Generic.List[System.String]]::new()
        foreach ($supportFilePath in @($templateParams['SupportFiles']))
        {
            if (-not [System.String]::IsNullOrWhiteSpace([string]$supportFilePath))
            {
                $supportFilesList.Add([string]$supportFilePath)
            }
        }
        if ($supportFilesList.Count -gt 0)
        {
            $invokeTemplateParams.SupportFiles = $supportFilesList
        }
    }

    Invoke-ADTTemplateRunner @invokeTemplateParams

    $resolvedPackageRoot = Resolve-PSADTPackageRoot -RootPath $PackageDir

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Package generation completed at '$PackageDir'." -InformationAction Continue
    }

    $recordingModuleSource = Join-Path $PSScriptRoot '..\_Shared\PSAppDeployToolkit.Recording.psm1'
    $recordingManifestSource = Join-Path $PSScriptRoot '..\_Shared\PSAppDeployToolkit.Recording.psd1'
    if (Test-Path -LiteralPath $recordingModuleSource -PathType Leaf)
    {
        $recordingDir = Join-Path $resolvedPackageRoot 'PSAppDeployToolkit.Recording'
        if (-not (Test-Path -LiteralPath $recordingDir -PathType Container))
        {
            New-Item -Path $recordingDir -ItemType Directory -Force | Out-Null
        }

        $recordingModuleDestination = Join-Path $recordingDir 'PSAppDeployToolkit.Recording.psm1'
        Copy-Item -Path $recordingModuleSource -Destination $recordingModuleDestination -Force

        if (Test-Path -LiteralPath $recordingManifestSource -PathType Leaf)
        {
            Copy-Item -Path $recordingManifestSource -Destination (Join-Path $recordingDir 'PSAppDeployToolkit.Recording.psd1') -Force
        }

        if ($UseInformationLogs)
        {
            Write-Information "::info::[$LogPrefix] Injected recording extension module: $recordingModuleDestination" -InformationAction Continue
        }
        else
        {
            Write-Verbose "[$LogPrefix] Injected recording extension module: $recordingModuleDestination"
        }
    }
    else
    {
        Write-Warning "[$LogPrefix] Recording extension module source not found: $recordingModuleSource"
    }

    Test-Path $PackageDir | Should -BeTrue
}

function script:Update-PSADTPackageDeployScript
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,
        [Parameter(Mandatory = $true)]
        [string]$SourceScript,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedContentPattern,
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [string]$AdditionalContentSourceDir,
        [switch]$UseInformationLogs
    )

    # Retained for backward compatibility with existing call sites.
    [void]$ExpectedContentPattern
    [void]$AdditionalContentSourceDir

    # Step 1: check source script exists.
    if (-not (Test-Path -LiteralPath $SourceScript -PathType Leaf))
    {
        throw "SourceScript file not found: $SourceScript"
    }

    # Step 2: check package directory exists.
    if (-not (Test-Path -LiteralPath $PackageDir -PathType Container))
    {
        throw "PackageDir folder not found: $PackageDir"
    }

    # Step 3: force copy source script to package directory.
    Copy-Item -LiteralPath $SourceScript -Destination $PackageDir -Force

    $destScriptPath = Join-Path -Path $PackageDir -ChildPath (Split-Path -Path $SourceScript -Leaf)
    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Copied '$SourceScript' to '$destScriptPath'." -InformationAction Continue
    }
    else
    {
        Write-Verbose "[$LogPrefix] Copied '$SourceScript' to '$destScriptPath'."
    }

    return (Get-Item -LiteralPath $destScriptPath -ErrorAction Stop)
}

function script:Copy-PSADTPackageInstallerToFiles
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$DeployScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$InstallerSource,
        [Parameter(Mandatory = $true)]
        [string]$InstallerLabel,
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [switch]$UseInformationLogs,
        [string]$ExpectedFileName
    )

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Step 4: Copying $InstallerLabel into Files folder..." -InformationAction Continue
    }
    else
    {
        Write-Verbose "[$LogPrefix] Step 4: Copying $InstallerLabel into Files folder..."
    }

    if (-not (Test-Path $InstallerSource))
    {
        $message = "$InstallerLabel not found at '$InstallerSource'"
        Write-Information "::error::[$LogPrefix] $message" -InformationAction Continue
        $true | Should -BeFalse -Because $message
        return
    }

    $scriptDir = Split-Path -Path $DeployScriptPath -Parent
    $filesDir = Join-Path -Path $scriptDir -ChildPath 'Files'
    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Deploy script path used for Files resolution: '$DeployScriptPath'" -InformationAction Continue
        Write-Information "::info::[$LogPrefix] Installer source path: '$InstallerSource'" -InformationAction Continue
        Write-Information "::info::[$LogPrefix] Resolved Files directory: '$filesDir'" -InformationAction Continue
    }
    if (-not (Test-Path $filesDir))
    {
        New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
    }

    Copy-Item -Path $InstallerSource -Destination $filesDir -Force
    $expectedName = if ([string]::IsNullOrWhiteSpace($ExpectedFileName)) { Split-Path -Path $InstallerSource -Leaf } else { $ExpectedFileName }
    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Expected copied installer path: '$(Join-Path $filesDir $expectedName)'" -InformationAction Continue
    }
    Test-Path (Join-Path $filesDir $expectedName) | Should -BeTrue
}

function script:Save-PSADTTestInstaller
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$LogPrefix = 'Test'
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container))
    {
        New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
        Write-Information "::info::[$LogPrefix] Created installer cache directory '$DestinationDirectory'." -InformationAction Continue
    }

    $destinationPath = Join-Path $DestinationDirectory $FileName
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf))
    {
        Write-Information "::info::[$LogPrefix] Downloading installer '$FileName' from '$Uri'..." -InformationAction Continue
        Invoke-WebRequest -Uri $Uri -OutFile $destinationPath -UseBasicParsing
    }
    else
    {
        Write-Information "::info::[$LogPrefix] Reusing cached installer '$destinationPath'." -InformationAction Continue
    }

    return $destinationPath
}

function script:Initialize-NotepadPlusPlusSccmEnvironment
{
    <#
        Prepares the local machine for the SCCM Notepad++ upgrade scenario by
        ensuring the legacy installer is available, installing the legacy version
        when needed, launching it to simulate an in-use app, and caching the
        target installer for package creation.
    #>
    param (
        [string]$LegacyInstallerDir = 'C:\Tools\SCCM\NotepadPlusPlus\6.2.3',
        [string]$LegacyInstallerName = 'npp.6.2.3.Installer.exe',
        [string]$LegacyInstallerUri = 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-2/npp.6.2.3.Installer.exe',
        [string]$TargetInstallerDir = 'C:\Tools\SCCM\NotepadPlusPlus\6.6.4',
        [string]$TargetInstallerName = 'npp.6.6.4.Installer.exe',
        [string]$TargetInstallerUri = 'https://github.com/notepad-plus-plus/old-releases/releases/download/v6x-5/npp.6.6.4.Installer.exe',
        [string]$LegacyVersionPattern = '^6\.(23|2\.3)(\.|$)',
        [string]$LogPrefix = 'Notepad++',
        [switch]$LaunchLegacyProcess
    )

    $legacyInstallerPath = Save-PSADTTestInstaller `
        -DestinationDirectory $LegacyInstallerDir `
        -FileName $LegacyInstallerName `
        -Uri $LegacyInstallerUri `
        -LogPrefix $LogPrefix

    $legacyExePath = Join-Path ${env:ProgramFiles(x86)} 'Notepad++\notepad++.exe'
    $installedLegacyVersion = $null
    if (Test-Path -LiteralPath $legacyExePath -PathType Leaf)
    {
        $installedLegacyVersion = (Get-Item -LiteralPath $legacyExePath).VersionInfo.FileVersion
    }

    if ($installedLegacyVersion -match $LegacyVersionPattern)
    {
        Write-Information "::info::[$LogPrefix] Legacy version already installed: $installedLegacyVersion" -InformationAction Continue
    }
    else
    {
        Write-Information "::info::[$LogPrefix] Installing legacy Notepad++ prerequisite from '$legacyInstallerPath'." -InformationAction Continue
        Start-Process -FilePath $legacyInstallerPath -ArgumentList '/S' -Wait -NoNewWindow
    }

    if ($LaunchLegacyProcess)
    {
        if (Test-Path -LiteralPath $legacyExePath -PathType Leaf)
        {
            Write-Information "::info::[$LogPrefix] Launching legacy Notepad++ process from '$legacyExePath'." -InformationAction Continue
            Start-Process -FilePath $legacyExePath
        }
        else
        {
            Write-Warning "[$LogPrefix] Launch path not found: $legacyExePath"
        }
    }

    $targetInstallerPath = Save-PSADTTestInstaller `
        -DestinationDirectory $TargetInstallerDir `
        -FileName $TargetInstallerName `
        -Uri $TargetInstallerUri `
        -LogPrefix $LogPrefix

    return @{
        LegacyInstallerPath = $legacyInstallerPath
        LegacyExePath       = $legacyExePath
        TargetInstallerPath = $targetInstallerPath
        TargetInstallerDir  = $TargetInstallerDir
    }
}

function script:Get-PSADTCmModulePath
{
    $cmModulePath = @(
        'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1',
        'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $cmModulePath -and $env:SMS_ADMIN_UI_PATH)
    {
        $candidate = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
        if (Test-Path $candidate)
        {
            $cmModulePath = $candidate
        }
    }

    return $cmModulePath
}

function script:New-PSADTAppTestContext
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceScriptRelativePath,
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        [Parameter(Mandatory = $true)]
        [string]$AppVendor,
        [Parameter(Mandatory = $true)]
        [string]$AppVersion,
        [Parameter(Mandatory = $true)]
        [string]$DeploymentTypeName,
        [Parameter(Mandatory = $true)]
        [string]$ContentSubPath,
        [string]$SourceFolderRelativePath
    )

    $sourceScript = Join-Path $PSScriptRoot $SourceScriptRelativePath
    $sourceFolder = if ([string]::IsNullOrWhiteSpace($SourceFolderRelativePath)) { $null } else { Join-Path $PSScriptRoot $SourceFolderRelativePath }
    $parallelSuffix = Get-PSADTParallelSafeSuffix

    return @{
        V3Dir              = $env:PSADT_TEMPLATE_V3_DIR
        V4Dir              = $env:PSADT_TEMPLATE_V4_DIR
        SourceScript       = $sourceScript
        SourceFolder       = $sourceFolder
        PackageDir         = $PackageDir
        AppName            = "$AppName$parallelSuffix"
        AppVendor          = $AppVendor
        AppVersion         = $AppVersion
        DeploymentTypeName = "$DeploymentTypeName$parallelSuffix"
        ContentUNC         = "\\$env:COMPUTERNAME\PSADT_Content`$\$ContentSubPath"
        TargetCollection   = if ($env:SCCM_TARGET_COLLECTION) { $env:SCCM_TARGET_COLLECTION } else { 'All Systems' }
        SiteCode           = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Operations Management' -Name 'Site Code' -ErrorAction SilentlyContinue).'Site Code'
        SiteServer         = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SMS\Setup' -Name 'Provider Location' -ErrorAction SilentlyContinue).'Provider Location'
        CmModulePath       = Get-PSADTCmModulePath
    }
}

function script:New-PSADTLogValidationAppConfig
{
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('V3', 'V4')]
        [string]$TemplateVersion,

        [Parameter(Mandatory = $true)]
        [string]$AppFolderName,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return @{
        TemplateVersion = $TemplateVersion
        AppFolderName   = $AppFolderName
        Name            = $Name
    }
}

function script:Invoke-PSADTApplicationWithDeploymentTypeSafe
{
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters,

        [string]$LogPrefix = 'PSADT'
    )

    $command = Get-Command -Name 'New-PSADTApplicationWithDeploymentType' -ErrorAction Stop
    $supportedParameters = $command.Parameters
    $filteredParameters = @{}

    foreach ($entry in $Parameters.GetEnumerator())
    {
        if ($supportedParameters.ContainsKey($entry.Key))
        {
            $filteredParameters[$entry.Key] = $entry.Value
        }
        else
        {
            Write-Verbose "[$LogPrefix] Skipping unsupported parameter '$($entry.Key)' for New-PSADTApplicationWithDeploymentType."
        }
    }

    New-PSADTApplicationWithDeploymentType @filteredParameters
}

function script:New-PSADTAppTestContextSafe
{
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Parameters,

        [string]$LogPrefix = 'PSADT'
    )

    $command = Get-Command -Name 'New-PSADTAppTestContext' -ErrorAction Stop
    $supportedParameters = $command.Parameters
    $filteredParameters = @{}

    foreach ($entry in $Parameters.GetEnumerator())
    {
        if ($supportedParameters.ContainsKey($entry.Key))
        {
            $filteredParameters[$entry.Key] = $entry.Value
        }
        else
        {
            Write-Verbose "[$LogPrefix] Skipping unsupported parameter '$($entry.Key)' for New-PSADTAppTestContext."
        }
    }

    New-PSADTAppTestContext @filteredParameters
}

function script:Assert-PSADTDeploymentLogValidation
{
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Install', 'Uninstall', 'Repair')]
        [string]$DeploymentType,

        [Parameter(Mandatory = $true)]
        [string]$LogPrefix
    )

    Write-Information "[$LogPrefix] Validating PSADT $DeploymentType log..." -InformationAction Continue
    $logValidation = Invoke-PsadtLogValidation -App $App -DeploymentType $DeploymentType
    $logValidation.Success | Should -BeTrue -Because "[$LogPrefix] PSADT log validation: $($logValidation.Message)"
}

function script:Assert-PSADTContentPathReady
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$CmModulePath,
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,
        [Parameter(Mandatory = $true)]
        [string]$ContentUNC,
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [switch]$UseInformationLogs
    )

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Step 5: Verifying SMB content share and package directories..." -InformationAction Continue
    }
    else
    {
        Write-Verbose "[$LogPrefix] Step 5: Verifying SMB content share and package directories..."
    }

    if (-not $CmModulePath)
    {
        Set-ItResult -Skipped -Because 'ConfigurationManager module not available - skipping SCCM steps'
        return $false
    }

    if (-not (Test-Path $PackageDir))
    {
        New-Item -ItemType Directory -Path $PackageDir -Force | Out-Null
        if ($UseInformationLogs)
        {
            Write-Information "::info::[$LogPrefix] Created package directory: $PackageDir" -InformationAction Continue
        }
        else
        {
            Write-Verbose "[$LogPrefix] Created package directory: $PackageDir"
        }
    }

    Test-Path $ContentUNC | Should -BeTrue -Because "SMB content UNC path '$ContentUNC' must exist"
    return $true
}

function script:Enter-CMSiteContext
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$SiteCode,
        [Parameter(Mandatory = $true)]
        [string]$SiteServer,
        [Parameter(Mandatory = $true)]
        [string]$CmModulePath
    )

    if ([string]::IsNullOrWhiteSpace($SiteCode))
    {
        throw 'siteCode cannot be null or empty'
    }
    if ([string]::IsNullOrWhiteSpace($SiteServer))
    {
        throw 'siteServer cannot be null or empty'
    }

    Import-Module $CmModulePath -ErrorAction Stop

    $siteServerRaw = [string]$SiteServer
    $siteServerHost = $siteServerRaw.Trim()
    $siteServerHost = $siteServerHost -replace '^\\\\', ''
    if ($siteServerHost -match '^([^\\]+)')
    {
        $siteServerHost = $matches[1]
    }

    $maxAttempts = 4
    $retryDelaySeconds = 15

    $envMaxAttempts = 0
    if ([int]::TryParse([string]$env:PSADT_CMSITE_CONNECT_MAX_ATTEMPTS, [ref]$envMaxAttempts) -and $envMaxAttempts -ge 1)
    {
        $maxAttempts = $envMaxAttempts
    }

    $envRetryDelay = 0
    if ([int]::TryParse([string]$env:PSADT_CMSITE_CONNECT_DELAY_SECONDS, [ref]$envRetryDelay) -and $envRetryDelay -ge 1)
    {
        $retryDelaySeconds = $envRetryDelay
    }

    Write-Information ("[SCCM] Entering CMSite context. SiteCode='{0}', SiteServer='{1}', SiteServerHost='{2}', CmModulePath='{3}', MaxAttempts={4}, RetryDelaySeconds={5}" -f $SiteCode, $siteServerRaw, $siteServerHost, $CmModulePath, $maxAttempts, $retryDelaySeconds) -InformationAction Continue

    try
    {
        $dnsAddresses = [System.Net.Dns]::GetHostAddresses($siteServerHost) | ForEach-Object { $_.IPAddressToString }
        if ($dnsAddresses)
        {
            Write-Information ("[SCCM] DNS resolve for '{0}': {1}" -f $siteServerHost, ($dnsAddresses -join ', ')) -InformationAction Continue
        }
    }
    catch
    {
        Write-Warning ("[SCCM] DNS resolve failed for '{0}': {1}" -f $siteServerHost, $_.Exception.Message)
    }

    $originalLocation = Get-Location
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue))
    {
        # -Scope Global is required: without it, the PSDrive is scoped to this
        # function and is automatically removed when Enter-CMSiteContext returns,
        # causing all subsequent SCCM cmdlets to fail with 'Cannot find drive'.
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++)
        {
            try
            {
                Write-Information ("[SCCM] Creating CMSite PSDrive attempt {0}/{1}: Name='{2}', Root='{3}'" -f $attempt, $maxAttempts, $SiteCode, $siteServerRaw) -InformationAction Continue
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -Scope Global -ErrorAction Stop | Out-Null
                Write-Information ("[SCCM] CMSite PSDrive '{0}' created successfully." -f $SiteCode) -InformationAction Continue
                break
            }
            catch
            {
                $exception = $_.Exception
                $errorMessage = $exception.Message
                $innerMessage = if ($exception.InnerException) { $exception.InnerException.Message } else { '' }
                $hResultHex = ('0x{0:X8}' -f ($exception.HResult -band 0xFFFFFFFF))

                Write-Warning ("[SCCM] New-PSDrive failed on attempt {0}/{1}. SiteCode='{2}', SiteServer='{3}', HResult={4}, Message='{5}', Inner='{6}'" -f $attempt, $maxAttempts, $SiteCode, $siteServerRaw, $hResultHex, $errorMessage, $innerMessage)

                $isTransientConnectivityError = $errorMessage -match 'SMS Provider reported an error|RPC server is unavailable|The network path was not found|The server is unavailable|timed out|timeout|WinRM|Cannot connect|connection.*failed|provider.*not available'
                if (-not $isTransientConnectivityError -or $attempt -ge $maxAttempts)
                {
                    throw
                }

                Write-Information ("[SCCM] Transient connectivity issue detected. Retrying in {0} second(s)..." -f $retryDelaySeconds) -InformationAction Continue
                Start-Sleep -Seconds $retryDelaySeconds
            }
        }
    }
    $siteDrive = [string]::Concat($SiteCode, [char]58)
    Set-Location -Path $siteDrive
    return $originalLocation
}

function script:Exit-CMSiteContext
{
    param (
        [object]$OriginalLocation,
        [string]$SiteCode
    )

    if ($OriginalLocation)
    {
        Set-Location $OriginalLocation
    }

    if (-not [string]::IsNullOrWhiteSpace($SiteCode))
    {
        Remove-PSDrive -Name $SiteCode -Scope Global -Force -ErrorAction SilentlyContinue
    }
}

function script:Invoke-PSADTInCMSiteContext
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$SiteCode,
        [Parameter(Mandatory = $true)]
        [string]$SiteServer,
        [Parameter(Mandatory = $true)]
        [string]$CmModulePath,
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $originalLocation = $null
    try
    {
        $originalLocation = Enter-CMSiteContext -SiteCode $SiteCode -SiteServer $SiteServer -CmModulePath $CmModulePath
    }
    catch
    {
        $contextErrorMessage = $_.Exception.Message
        $isCmsiteConnectivityError = $contextErrorMessage -match 'SMS Provider reported an error|Cannot find drive|RPC server is unavailable|Access is denied|Configuration Manager site|The network path was not found|The server is unavailable|timed out|timeout|WinRM|Cannot connect|connection.*failed|provider.*not available'

        if ($isCmsiteConnectivityError)
        {
            $skipReason = "SCCM site context unavailable for '$SiteCode' on '$SiteServer': $contextErrorMessage"
            if (Get-Command -Name Set-ItResult -ErrorAction SilentlyContinue)
            {
                Set-ItResult -Skipped -Because $skipReason
                Write-Warning $skipReason
                return $null
            }
        }

        throw
    }

    try
    {
        return (& $ScriptBlock)
    }
    finally
    {
        Exit-CMSiteContext -OriginalLocation $originalLocation -SiteCode $SiteCode
    }
}

function script:Remove-CMApplicationIfExists
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    if (Get-CMApplication -Name $AppName -ErrorAction SilentlyContinue)
    {
        $existingDeps = Get-CMApplicationDeployment -Name $AppName -ErrorAction SilentlyContinue
        foreach ($dep in $existingDeps)
        {
            Remove-CMApplicationDeployment -Name $AppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
        }
        Remove-CMApplication -Name $AppName -Force
        Start-Sleep -Seconds 2
    }
}

function script:Get-PSADTDeploymentCommands
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageDir
    )

    if (Test-Path (Join-Path $PackageDir 'Invoke-AppDeployToolkit.exe'))
    {
        return @{
            Install   = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive'
            Uninstall = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Interactive'
        }
    }
    if (Test-Path (Join-Path $PackageDir 'Deploy-Application.exe'))
    {
        return @{
            Install   = 'Deploy-Application.exe -DeploymentType Install -DeployMode Interactive'
            Uninstall = 'Deploy-Application.exe -DeploymentType Uninstall -DeployMode Interactive'
        }
    }

    if (Test-Path (Join-Path $PackageDir 'Deploy-Application.ps1'))
    {
        return @{
            Install   = 'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Deploy-Application.ps1" -DeploymentType Install'
            Uninstall = 'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Deploy-Application.ps1" -DeploymentType Uninstall'
        }
    }

    return @{
        Install   = 'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install'
        Uninstall = 'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Uninstall'
    }
}

function script:New-PSADTApplicationWithDeploymentType
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        [Parameter(Mandatory = $true)]
        [string]$Vendor,
        [Parameter(Mandatory = $true)]
        [string]$Version,
        [Parameter(Mandatory = $true)]
        [string]$DeploymentTypeName,
        [Parameter(Mandatory = $true)]
        [string]$ContentUNC,
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,
        [Parameter(Mandatory = $true)]
        [string]$DetectScript,
        [Parameter(Mandatory = $true)]
        [string]$Description,
        [Parameter(Mandatory = $false)]
        [string]$InstallCommand,
        [Parameter(Mandatory = $false)]
        [string]$UninstallCommand
    )

    Remove-CMApplicationIfExists -AppName $AppName

    New-CMApplication `
        -Name            $AppName `
        -Publisher       $Vendor `
        -SoftwareVersion $Version `
        -LocalizedName   $AppName `
        -Description     $Description | Out-Null

    $commands = Get-PSADTDeploymentCommands -PackageDir $PackageDir
    if ($InstallCommand)
    {
        $commands.Install = $InstallCommand
    }
    if ($UninstallCommand)
    {
        $commands.Uninstall = $UninstallCommand
    }
    Add-CMScriptDeploymentType `
        -ApplicationName           $AppName `
        -DeploymentTypeName        $DeploymentTypeName `
        -ContentLocation           $ContentUNC `
        -InstallCommand            $commands.Install `
        -UninstallCommand          $commands.Uninstall `
        -ScriptLanguage            PowerShell `
        -ScriptText                $DetectScript `
        -InstallationBehaviorType  InstallForSystem `
        -LogonRequirementType      WhetherOrNotUserLoggedOn `
        -RebootBehavior            BasedOnExitCode `
        -SlowNetworkDeploymentMode Download `
        -RequireUserInteraction `
        -MaximumRuntimeMins        30 `
        -EstimatedRuntimeMins      5 | Out-Null

    $dt = Get-CMDeploymentType -ApplicationName $AppName -DeploymentTypeName $DeploymentTypeName
    Add-CMDeploymentTypeReturnCode -InputObject $dt -ReturnCode 3010 -CodeType SoftReboot -Name 'Reboot Required' | Out-Null
    Add-CMDeploymentTypeReturnCode -InputObject $dt -ReturnCode 1641 -CodeType HardReboot -Name 'Reboot Initiated' | Out-Null

    $created = Get-CMApplication -Name $AppName -ErrorAction SilentlyContinue
    $created | Should -Not -BeNullOrEmpty
}

function script:Start-PSADTContentDistributionAndAssert
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix,
        [int]$MaxWaitSeconds = 600,
        [int]$PollIntervalSeconds = 60
    )

    $dpGroups = Get-CMDistributionPointGroup -ErrorAction SilentlyContinue
    $dpList = Get-CMDistributionPoint -ErrorAction SilentlyContinue

    if ($dpGroups)
    {
        foreach ($grp in $dpGroups)
        {
            Start-CMContentDistribution -ApplicationName $AppName `
                -DistributionPointGroupName $grp.Name -ErrorAction SilentlyContinue | Out-Null
        }
    }
    elseif ($dpList)
    {
        foreach ($dp in $dpList)
        {
            Start-CMContentDistribution -ApplicationName $AppName `
                -DistributionPointName $dp.NetworkOSPath.TrimStart('\\') -ErrorAction SilentlyContinue | Out-Null
        }
    }
    else
    {
        Write-Information "::warning::[$LogPrefix] No distribution points or DP groups found - content distribution skipped." -InformationAction Continue
    }

    $packageId = (Get-CMApplication -Name $AppName -ErrorAction SilentlyContinue).PackageID
    if (-not $packageId)
    {
        Write-Information "::warning::[$LogPrefix] Could not retrieve PackageID for distribution status check." -InformationAction Continue
        return
    }

    $elapsed = 0
    $distributionStatus = $null
    do
    {
        $distributionStatus = Get-CMDistributionStatus -Id $packageId -ErrorAction SilentlyContinue
        if ($distributionStatus)
        {
            Write-Verbose "[$LogPrefix] Distribution status (elapsed ${elapsed}s): Targeted=$($distributionStatus.Targeted) Success=$($distributionStatus.NumberSuccess) InProgress=$($distributionStatus.NumberInProgress) Errors=$($distributionStatus.NumberErrors)"
            if ($distributionStatus.NumberSuccess -ge $distributionStatus.Targeted -and $distributionStatus.Targeted -gt 0)
            {
                break
            }
        }

        if ($elapsed -lt $MaxWaitSeconds)
        {
            Write-Verbose "[$LogPrefix] Distribution not yet complete - waiting ${PollIntervalSeconds}s before next check..."
            Start-Sleep -Seconds $PollIntervalSeconds
            $elapsed += $PollIntervalSeconds
        }
        else
        {
            break
        }
    }
    while ($elapsed -le $MaxWaitSeconds)

    $distributionStatus | Should -Not -BeNullOrEmpty -Because 'Content distribution status must exist'
    $distributionStatus.NumberSuccess | Should -Be $distributionStatus.Targeted -Because "All $($distributionStatus.Targeted) targeted distribution points must have received the content successfully (waited up to ${MaxWaitSeconds}s)"
}

function script:New-PSADTRequiredDeployment
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        [Parameter(Mandatory = $true)]
        [string]$TargetCollection,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Install', 'Uninstall')]
        [string]$DeployAction,
        [Parameter(Mandatory = $true)]
        [string]$LogPrefix
    )

    if ($TargetCollection -ne 'All Systems')
    {
        $col = Get-CMDeviceCollection -Name $TargetCollection -ErrorAction SilentlyContinue
        $col | Should -Not -BeNullOrEmpty -Because "Collection '$TargetCollection' must exist in SCCM"
        Write-Verbose "[$LogPrefix] Collection validated: $TargetCollection ($($col.MemberCount) device(s))"
    }

    $existingDeployments = Get-CMApplicationDeployment -Name $AppName -CollectionName $TargetCollection -ErrorAction SilentlyContinue
    foreach ($dep in $existingDeployments)
    {
        Remove-CMApplicationDeployment -Name $AppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
        Write-Verbose "[$LogPrefix] Removed existing deployment: $AppName -> $($dep.CollectionName)"
    }
    if ($existingDeployments)
    {
        Start-Sleep -Seconds 2
    }

    New-CMApplicationDeployment `
        -Name                       $AppName `
        -CollectionName             $TargetCollection `
        -DeployAction               $DeployAction `
        -DeployPurpose              Required `
        -UserNotification           DisplaySoftwareCenterOnly `
        -TimeBaseOn                 LocalTime `
        -OverrideServiceWindow      $false `
        -RebootOutsideServiceWindow $false | Out-Null

    $createdDeploy = Get-CMApplicationDeployment -Name $AppName -CollectionName $TargetCollection -ErrorAction SilentlyContinue
    $createdDeploy | Should -Not -BeNullOrEmpty -Because "$DeployAction deployment of '$AppName' to '$TargetCollection' must be created successfully"
    Write-Information "[$LogPrefix] $DeployAction deployment created: $AppName -> $TargetCollection (Required)" -InformationAction Continue
}

function script:Assert-PSADTDeploymentSummarySuccess
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,
        [Parameter(Mandatory = $true)]
        [string]$SiteCode,
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [int]$MaxWaitSeconds = 1800,
        [int]$PollInterval = 180
    )

    $summary = Invoke-WinSCPPollDeploymentStatus `
        -AppName        $AppName `
        -SiteCode       $SiteCode `
        -Label          $Label `
        -MaxWaitSeconds $MaxWaitSeconds `
        -PollInterval   $PollInterval
    $summary | Should -Not -BeNullOrEmpty -Because "$Label status must exist"
    $summary.NumberSuccess | Should -BeGreaterThan 0 -Because "At least one device must have successfully completed $Label (waited up to ${MaxWaitSeconds}s)"
    return $summary
}
