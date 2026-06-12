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
        [int]$MaxWaitSeconds = 3600,
        [int]$PollInterval = 180
    )

    $elapsed = 0
    $summary = $null
    $cimNamespace = "root\SMS\Site_$SiteCode"

    do
    {
        $deployments = Get-CMDeployment -SoftwareName $AppName -ErrorAction SilentlyContinue
        $deployments | ForEach-Object { Invoke-CMDeploymentSummarization -DeploymentId $_.DeploymentId | Out-Null }

        $summary = $null
        if (-not [string]::IsNullOrWhiteSpace($SiteCode))
        {
            $summary = Get-CimInstance -Namespace $cimNamespace -ClassName SMS_DeploymentSummary -ErrorAction SilentlyContinue | Where-Object { $_.ApplicationName -eq $AppName } | Select-Object -First 1
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
        $summary = Get-CimInstance -Namespace $cimNamespace -ClassName SMS_DeploymentSummary -ErrorAction SilentlyContinue | Where-Object { $_.ApplicationName -eq $AppName } | Select-Object -First 1
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
        [Parameter(Mandatory = $true)]
        [string]$SourceScript,
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
    Test-Path $SourceScript | Should -BeTrue -Because "$SourceScriptLabel must exist"

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

    if ($UseInformationLogs)
    {
        Write-Information "::info::[$LogPrefix] Step 3: Updating Invoke-AppDeployToolkit.ps1..." -InformationAction Continue
    }
    else
    {
        Write-Verbose "[$LogPrefix] Step 3: Updating Invoke-AppDeployToolkit.ps1..."
    }

    $allDestScripts = Get-ChildItem -Path $PackageDir -Filter 'Invoke-AppDeployToolkit.ps1' -Recurse -File -ErrorAction SilentlyContinue
    $destScript = $allDestScripts | Select-Object -First 1
    $destScript | Should -Not -BeNullOrEmpty -Because 'Invoke-AppDeployToolkit.ps1 must exist in the copied V4 template'

    if (-not [string]::IsNullOrWhiteSpace($AdditionalContentSourceDir))
    {
        Copy-Item -Path "$AdditionalContentSourceDir\*" -Destination $PackageDir -Recurse -Force
    }
    else
    {
        Copy-Item -Path $SourceScript -Destination $destScript.FullName -Force
    }

    $content = Get-Content -Path $destScript.FullName -Raw
    $content | Should -Match $ExpectedContentPattern
    return $destScript
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
        Write-Information "::warning::[$LogPrefix] $InstallerLabel not found at '$InstallerSource', skipping installer copy step." -InformationAction Continue
        return
    }

    $scriptDir = Split-Path -Path $DeployScriptPath -Parent
    $filesDir = Join-Path -Path $scriptDir -ChildPath 'Files'
    if (-not (Test-Path $filesDir))
    {
        New-Item -ItemType Directory -Path $filesDir -Force | Out-Null
    }

    Copy-Item -Path $InstallerSource -Destination $filesDir -Force
    $expectedName = if ([string]::IsNullOrWhiteSpace($ExpectedFileName)) { Split-Path -Path $InstallerSource -Leaf } else { $ExpectedFileName }
    Test-Path (Join-Path $filesDir $expectedName) | Should -BeTrue
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
    $originalLocation = Get-Location
    if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue))
    {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
    }
    Set-Location ($SiteCode + ':')
    return $originalLocation
}

function script:Exit-CMSiteContext
{
    param (
        [object]$OriginalLocation
    )

    if ($OriginalLocation)
    {
        Set-Location $OriginalLocation
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
        [string]$Description
    )

    Remove-CMApplicationIfExists -AppName $AppName

    New-CMApplication `
        -Name            $AppName `
        -Publisher       $Vendor `
        -SoftwareVersion $Version `
        -LocalizedName   $AppName `
        -Description     $Description | Out-Null

    $commands = Get-PSADTDeploymentCommands -PackageDir $PackageDir
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
        [int]$MaxWaitSeconds = 3600,
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
