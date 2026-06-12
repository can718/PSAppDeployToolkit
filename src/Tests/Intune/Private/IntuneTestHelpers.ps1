#pragma warning disable PSPlaceOpenBrace

<#
.SYNOPSIS
    Shared helper functions for Intune integration tests.

.DESCRIPTION
    This file provides reusable functions for:
    - TerraForge test-run reporting
    - PSADT template and package preparation
    - IntuneWinAppUtil wrapping
    - Intune Win32 app upload and assignment
    - MDM sync and IME readiness
    - Registry-based installation polling
#>

# ---------------------------------------------------------------------------
# Region: TerraForge Reporting
# ---------------------------------------------------------------------------

function Initialize-TerraForgeReporting
{
    <#
    .SYNOPSIS
        Loads the TerraForge helper script and obtains an access token if
        the required environment variables are set.
    .OUTPUTS
        [hashtable] with keys: Enabled, AccessToken, TestRunId, ApiBaseUrl.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )

    $result = @{
        Enabled = $false
        AccessToken = $null
        TestRunId = $env:TEST_RUN_ID
        ApiBaseUrl = $env:TERRAFORGE_API_BASE_URL
    }

    $helperPath = [System.IO.Path]::GetFullPath((Join-Path $ScriptRoot '..\..\..\.github\scripts\TerraForge-AgentHelper.ps1'))
    Write-Information "[TerraForge] Helper script path: $helperPath  Exists=$(Test-Path $helperPath)" -InformationAction Continue
    if (Test-Path $helperPath)
    {
        try { . $helperPath }
        catch { Write-Warning "[TerraForge] Failed to load helper script: $($_.Exception.Message)" }
    }

    if ($result.TestRunId -and $result.ApiBaseUrl)
    {
        if (Get-Command 'Get-TerraForgeAuthToken' -ErrorAction SilentlyContinue)
        {
            try
            {
                $result.AccessToken = Get-TerraForgeAuthToken `
                    -ManagedIdentityClientId $env:INFRA_MI_CLIENT_ID `
                    -KeyVaultName            $env:INFRA_KEYVAULT `
                    -ApiKeySecretName        $env:TERRAFORGE_API_KEY_SECRET `
                    -ApiBaseUrl              $result.ApiBaseUrl
                $result.Enabled = $true
                Write-Information "[TerraForge] Reporting enabled for TestRunId: $($result.TestRunId)" -InformationAction Continue
            }
            catch
            {
                Write-Warning "[TerraForge] Could not obtain access token, reporting disabled: $($_.Exception.Message)"
            }
        }
        else
        {
            Write-Warning "[TerraForge] Helper script not found or failed to load -- reporting disabled."
        }
    }

    return $result
}

function Invoke-TFReportTestCase
{
    <#
    .SYNOPSIS
        Creates a TerraForge test run result entry before the test executes.
    .OUTPUTS
        The result ID string, or $null if reporting is disabled.
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable]$TFState,
        [string]$TestClass,
        [string]$TestMethod
    )

    if (-not $TFState.Enabled) { return $null }

    if ([string]::IsNullOrWhiteSpace($TestMethod))
    {
        Write-Warning "[TerraForge] Skipping result entry creation: could not resolve test name."
        return $null
    }

    try
    {
        $result = New-TestRunResults `
            -ApiBaseUrl  $TFState.ApiBaseUrl `
            -AccessToken $TFState.AccessToken `
            -TestRunId   $TFState.TestRunId `
            -TestClass   $TestClass `
            -SessionId   $env:TEST_SESSION_ID `
            -ProductName $TestMethod `
            -MachineId   $env:COMPUTERNAME
        Write-Information "[TerraForge] Created result entry Id=$($result.Id) for: $TestClass / $TestMethod" -InformationAction Continue
        return $result.Id
    }
    catch
    {
        Write-Warning "[TerraForge] Failed to create result entry for '$TestMethod': $($_.Exception.Message)"
        return $null
    }
}

function Invoke-TFUpdateTestCase
{
    <#
    .SYNOPSIS
        Updates a TerraForge test run result after the test completes.
    .DESCRIPTION
        Result codes: 2 = Passed, 0 = Failed, $null = Skipped.
        Derives the outcome from ErrorRecord count and the Skipped flag.
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable]$TFState,
        [string]$ResultId,
        [object]$TestResult
    )

    if (-not $TFState.Enabled -or -not $ResultId) { return }

    try
    {
        $resultCode = if ($TestResult.Skipped)
        {
            $null
        }
        elseif ($TestResult.ErrorRecord -and $TestResult.ErrorRecord.Count -gt 0)
        {
            0
        }
        else
        {
            2
        }
        $errorMsg = if ($TestResult.ErrorRecord -and $TestResult.ErrorRecord.Count -gt 0)
        {
            $TestResult.ErrorRecord[0].Exception.Message
        }
        else
        {
            $null
        }

        Update-TestRunResults `
            -ApiBaseUrl       $TFState.ApiBaseUrl `
            -AccessToken      $TFState.AccessToken `
            -TestRunResultId  $ResultId `
            -Result           $resultCode `
            -ErrorMessage     $errorMsg
        Write-Verbose "[TerraForge] Updated result Id=$ResultId -> code=$resultCode"
    }
    catch
    {
        Write-Warning "[TerraForge] Failed to update result Id=${ResultId}: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Region: Package Preparation
# ---------------------------------------------------------------------------

function New-IntuneTestWorkDir
{
    <#
    .SYNOPSIS
        Prepares a working directory for an app by copying the PSADT template,
        the installer files, and the runner script.
    .OUTPUTS
        [hashtable] with keys: WorkDir, FilesDir.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$AppFolderName,

        [Parameter(Mandatory)]
        [string]$BasePath,

        [Parameter(Mandatory)]
        [string]$InstallerSourceDir,

        [Parameter(Mandatory)]
        [string]$RunnerScriptPath
    )

    $workDir = Join-Path $BasePath $AppFolderName
    New-Item -Path $workDir -ItemType Directory -Force | Out-Null

    # Step 1: Copy PSADT v4 template
    $v4Path = $env:PSADT_TEMPLATE_V4_DIR
    if (-not (Test-Path $v4Path))
    {
        throw "PSADT v4 template folder missing: $v4Path"
    }
    Copy-Item -Path (Join-Path $v4Path '*') -Destination $workDir -Recurse -Force
    Write-Information "[$AppFolderName] Copied PSADT template from '$v4Path' to '$workDir'." -InformationAction Continue

    # Step 2: Copy installer files
    $filesDir = Join-Path $workDir 'Files'
    if (-not (Test-Path $filesDir))
    {
        New-Item -Path $filesDir -ItemType Directory -Force | Out-Null
    }
    $installerFile = Get-ChildItem -Path $InstallerSourceDir -File | Select-Object -First 1
    if (-not $installerFile)
    {
        throw "No installer file found in '$InstallerSourceDir'."
    }
    Copy-Item -Path $installerFile.FullName -Destination $filesDir -Force
    Write-Information "[$AppFolderName] Copied installer '$($installerFile.Name)' to '$filesDir'." -InformationAction Continue

    # Step 3: Copy Invoke-AppDeployToolkit.ps1 runner script
    $targetScript = Join-Path $workDir 'Invoke-AppDeployToolkit.ps1'
    Copy-Item -Path $RunnerScriptPath -Destination $targetScript -Force
    Write-Information "[$AppFolderName] Copied runner script to '$targetScript'." -InformationAction Continue

    return @{
        WorkDir = $workDir
        FilesDir = $filesDir
    }
}

function New-IntuneWinPackage
{
    <#
    .SYNOPSIS
        Wraps a working directory into an .intunewin package using IntuneWinAppUtil,
        then renames the output to match the installer's base name.
    .OUTPUTS
        [hashtable] with keys: IntuneWinPath, DisplayName.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$WorkDir,

        [Parameter(Mandatory)]
        [string]$IntuneWinAppUtilPath,

        [string]$SetupFileName = 'Invoke-AppDeployToolkit.exe'
    )

    # Wrap with IntuneWinAppUtil
    & $IntuneWinAppUtilPath -c $WorkDir -s $SetupFileName -o $WorkDir
    $intunewinFile = Join-Path $WorkDir 'Invoke-AppDeployToolkit.intunewin'
    if (-not (Test-Path $intunewinFile))
    {
        throw "IntuneWinAppUtil did not produce expected output: $intunewinFile"
    }

    # Find the actual installer (msi/exe) to derive the display name
    $filesDir = Join-Path $WorkDir 'Files'
    $packageFile = Get-ChildItem -Path $filesDir -File | Where-Object {
        $_.Extension -in '.msi', '.exe'
    } | Select-Object -First 1

    if (-not $packageFile)
    {
        throw "No .msi or .exe found in '$filesDir' to derive display name."
    }

    $displayName = $packageFile.BaseName
    $newFileName = "$displayName.intunewin"
    $newIntuneWinFile = Join-Path $WorkDir $newFileName
    Rename-Item -Path $intunewinFile -NewName $newFileName -Force
    Write-Information "Renamed intunewin to '$newIntuneWinFile'." -InformationAction Continue

    if (-not (Test-Path $newIntuneWinFile))
    {
        throw "Renamed intunewin file not found: $newIntuneWinFile"
    }

    return @{
        IntuneWinPath = $newIntuneWinFile
        DisplayName = $displayName
    }
}

# ---------------------------------------------------------------------------
# Region: Intune Upload & Assignment
# ---------------------------------------------------------------------------

function Remove-ExistingIntuneWin32App
{
    <#
    .SYNOPSIS
        Removes any existing Win32 apps from Intune that match the given DisplayName.
    .DESCRIPTION
        Queries the Intune Graph API for apps matching the DisplayName and deletes
        each one found. Waits briefly after deletion to allow API propagation.
    .OUTPUTS
        The number of apps removed.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$DisplayName,

        [int]$PropagationDelaySeconds = 10
    )

    $existingApps = Get-IntuneWin32App -DisplayName $DisplayName -ErrorAction SilentlyContinue
    if (-not $existingApps)
    {
        Write-Information "No existing Intune app found with DisplayName '$DisplayName'." -InformationAction Continue
        return 0
    }

    $removedCount = 0
    foreach ($app in $existingApps)
    {
        Write-Information "Removing existing Intune app '$($app.displayName)' (Id: $($app.id))..." -InformationAction Continue
        Remove-IntuneWin32App -ID $app.id
        $removedCount++
    }

    if ($removedCount -gt 0 -and $PropagationDelaySeconds -gt 0)
    {
        # Allow time for Graph API to propagate the deletion.
        Start-Sleep -Seconds $PropagationDelaySeconds
    }

    Write-Information "Removed $removedCount existing Intune app(s) with DisplayName '$DisplayName'." -InformationAction Continue
    return $removedCount
}

function Publish-IntuneWin32App
{
    <#
    .SYNOPSIS
        Uploads a Win32 app to Intune and waits for it to become visible
        via the Graph API.
    .OUTPUTS
        The Win32 app object returned by Get-IntuneWin32App.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [object]$DetectionRule,

        [object]$RequirementRule,

        [string]$InstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive',
        [string]$UninstallCmd = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Interactive',
        [string]$Publisher = 'Autotest',

        [int]$MaxRetries = 12,
        [int]$RetryIntervalSeconds = 10
    )

    if (-not $RequirementRule)
    {
        $RequirementRule = New-IntuneWin32AppRequirementRule -Architecture 'x64x86' -MinimumSupportedWindowsRelease 'W10_1607'
    }

    # Remove existing app with the same DisplayName before uploading.
    $null = Remove-ExistingIntuneWin32App -DisplayName $DisplayName

    $null = Add-IntuneWin32App -FilePath $FilePath -DisplayName $DisplayName `
        -Description "PSADT $DisplayName deployment" `
        -Publisher $Publisher -InstallExperience 'system' -RestartBehavior 'suppress' `
        -DetectionRule $DetectionRule -RequirementRule $RequirementRule `
        -InstallCommandLine $InstallCmd -UninstallCommandLine $UninstallCmd

    # Intune Graph API has eventual consistency; retry until the app is visible.
    $win32App = $null
    $retryCount = 0
    while (-not $win32App -and $retryCount -lt $MaxRetries)
    {
        Start-Sleep -Seconds $RetryIntervalSeconds
        $win32App = Get-IntuneWin32App -DisplayName $DisplayName -Verbose |
            Sort-Object -Property createdDateTime -Descending |
            Select-Object -First 1
        $retryCount++
    }

    return $win32App
}

# ---------------------------------------------------------------------------
# Region: MDM Sync & IME Readiness
# ---------------------------------------------------------------------------

function Wait-IntuneManagementExtension
{
    <#
    .SYNOPSIS
        Ensures IntuneManagementExtension (IME) is running. Restarts it if
        already present, or triggers MDM sync and polls until IME is installed.
    #>
    param (
        [int]$MaxWaitSeconds = 900,
        [int]$PollIntervalSeconds = 30,
        [int]$MaxSyncAttempts = 3
    )

    $imeSvc = Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue
    if ($imeSvc)
    {
        Write-Information "Restarting service 'IntuneManagementExtension' (current state: $($imeSvc.Status))..." -InformationAction Continue
        Restart-Service -Name 'IntuneManagementExtension' -Force -ErrorAction SilentlyContinue
        $imeSvc.Refresh()
        Write-Information "Service 'IntuneManagementExtension' state after restart: $($imeSvc.Status)" -InformationAction Continue
        return
    }

    Write-Information "IntuneManagementExtension not found; triggering MDM sync and waiting up to $($MaxWaitSeconds / 60) min..." -InformationAction Continue
    $waited = 0
    $installed = $false
    $syncCount = 0
    # Trigger sync at: 0 s, 300 s (5 min), 600 s (10 min)
    $syncAtSeconds = @(0, 300, 600) | Select-Object -First $MaxSyncAttempts

    while ($waited -le $MaxWaitSeconds)
    {
        # Trigger an MDM sync at scheduled intervals.
        if ($syncCount -lt $MaxSyncAttempts -and $waited -ge $syncAtSeconds[$syncCount])
        {
            Write-Information "Triggering MDM full sync (attempt $($syncCount + 1)/$MaxSyncAttempts) at $waited s..." -InformationAction Continue
            Invoke-MdmSync
            $syncCount++
        }

        $imeSvc = Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue
        if ($imeSvc)
        {
            $installed = $true
            Write-Information "IntuneManagementExtension installed after $waited s." -InformationAction Continue
            break
        }

        if ($waited -ge $MaxWaitSeconds) { break }
        Write-Information "Waiting for IntuneManagementExtension... ($($waited + $PollIntervalSeconds) / $MaxWaitSeconds s elapsed)" -InformationAction Continue
        Start-Sleep -Seconds $PollIntervalSeconds
        $waited += $PollIntervalSeconds
    }

    if (-not $installed)
    {
        throw "IntuneManagementExtension was not installed within $($MaxWaitSeconds / 60) minutes after $MaxSyncAttempts MDM sync attempts."
    }
}

function Invoke-MdmSync
{
    <#
    .SYNOPSIS
        Triggers MDM scheduled sync tasks for the first Azure AD / Intune enrollment found.
    #>
    try
    {
        $enrollmentId = (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue | Where-Object {
                (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).EnrollmentType -eq 6
            } | Select-Object -First 1).PSChildName

        if ($enrollmentId)
        {
            $taskPath = "\Microsoft\Windows\EnterpriseMgmt\$enrollmentId\"
            $syncTasks = Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue
            foreach ($task in $syncTasks)
            {
                Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName -ErrorAction SilentlyContinue
            }
            Write-Information "MDM sync tasks triggered for enrollment: $enrollmentId" -InformationAction Continue
        }
        else
        {
            Write-Information "No MDM enrollment (EnrollmentType=6) found; cannot trigger sync." -InformationAction Continue
        }
    }
    catch
    {
        Write-Information "MDM sync trigger failed: $($_.Exception.Message)" -InformationAction Continue
    }
}

# ---------------------------------------------------------------------------
# Region: Installation Detection
# ---------------------------------------------------------------------------

function Wait-AppInstallation
{
    <#
    .SYNOPSIS
        Polls registry uninstall keys for a specific app version, checking
        both native and WOW6432Node paths for 32-bit compatibility.
    .DESCRIPTION
        Enumerates all subkeys under the Uninstall registry paths and matches
        by DisplayName, so apps registered under a GUID key are also found.
    .OUTPUTS
        $true if the app was detected within the timeout, $false otherwise.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$ValueName,

        [Parameter(Mandatory)]
        [string]$ExpectedValue,

        [int]$MaxWaitSeconds = 900,
        [int]$PollIntervalSeconds = 60,
        [int]$SyncIntervalSeconds = 180
    )

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $waited = 0
    $verified = $false
    $nextSyncAt = 0

    Write-Information "Polling for '$DisplayName' installation (DisplayName='$DisplayName', timeout: $($MaxWaitSeconds / 60) min)..." -InformationAction Continue
    while ($waited -lt $MaxWaitSeconds)
    {
        foreach ($root in $uninstallRoots)
        {
            $subKeys = Get-ChildItem -Path $root -ErrorAction SilentlyContinue
            foreach ($subKey in $subKeys)
            {
                $props = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
                if ($props -and $props.DisplayName -eq $DisplayName -and $props.$ValueName -eq $ExpectedValue)
                {
                    $verified = $true
                    Write-Information "'$DisplayName' detected in registry after $waited s (path: $($subKey.PSPath))." -InformationAction Continue
                    Write-Information "[Succeed] '$DisplayName' installation verification successful." -InformationAction Continue
                    break
                }
            }
            if ($verified) { break }
        }
        if ($verified) { break }

        # Trigger MDM sync and restart IME at regular intervals to accelerate install.
        if ($waited -ge $nextSyncAt)
        {
            Write-Information "'$DisplayName' not yet installed; triggering MDM sync and restarting IME at $waited s..." -InformationAction Continue
            Invoke-MdmSync
            $imeSvc = Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue
            if ($imeSvc)
            {
                Restart-Service -Name 'IntuneManagementExtension' -Force -ErrorAction SilentlyContinue
            }
            $nextSyncAt = $waited + $SyncIntervalSeconds
        }

        Write-Information "'$DisplayName' not yet installed; waiting $PollIntervalSeconds s... ($($waited + $PollIntervalSeconds) / $MaxWaitSeconds s elapsed)" -InformationAction Continue
        Start-Sleep -Seconds $PollIntervalSeconds
        $waited += $PollIntervalSeconds
    }

    return $verified
}

function Wait-AppUninstallation
{
    <#
    .SYNOPSIS
        Polls registry uninstall keys until a specific app version is no longer
        present, checking both native and WOW6432Node paths.
    .DESCRIPTION
        Enumerates all subkeys under the Uninstall registry paths and matches
        by DisplayName. Returns $true once the app is no longer found within
        the timeout, $false if it is still detected after the timeout expires.
    .OUTPUTS
        $true if the app was confirmed removed within the timeout, $false otherwise.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$ValueName,

        [Parameter(Mandatory)]
        [string]$ExpectedValue,

        [int]$MaxWaitSeconds = 1200,
        [int]$PollIntervalSeconds = 60,
        [int]$SyncIntervalSeconds = 180
    )

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $waited = 0
    $removed = $false
    $nextSyncAt = 0

    Write-Information "Polling for '$DisplayName' uninstallation (DisplayName='$DisplayName', timeout: $($MaxWaitSeconds / 60) min)..." -InformationAction Continue
    while ($waited -lt $MaxWaitSeconds)
    {
        $found = $false
        foreach ($root in $uninstallRoots)
        {
            $subKeys = Get-ChildItem -Path $root -ErrorAction SilentlyContinue
            foreach ($subKey in $subKeys)
            {
                $props = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
                if ($props -and $props.DisplayName -eq $DisplayName -and $props.$ValueName -eq $ExpectedValue)
                {
                    $found = $true
                    break
                }
            }
            if ($found) { break }
        }

        if (-not $found)
        {
            $removed = $true
            Write-Information "'$DisplayName' no longer detected in registry after $waited s." -InformationAction Continue
            Write-Information "[Succeed] '$DisplayName' uninstallation verification successful." -InformationAction Continue
            break
        }

        # Trigger MDM sync and restart IME at regular intervals to accelerate uninstall.
        if ($waited -ge $nextSyncAt)
        {
            Write-Information "'$DisplayName' still installed; triggering MDM sync and restarting IME at $waited s..." -InformationAction Continue
            Invoke-MdmSync
            $imeSvc = Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue
            if ($imeSvc)
            {
                Restart-Service -Name 'IntuneManagementExtension' -Force -ErrorAction SilentlyContinue
            }
            $nextSyncAt = $waited + $SyncIntervalSeconds
        }

        Write-Information "'$DisplayName' still installed; waiting $PollIntervalSeconds s... ($($waited + $PollIntervalSeconds) / $MaxWaitSeconds s elapsed)" -InformationAction Continue
        Start-Sleep -Seconds $PollIntervalSeconds
        $waited += $PollIntervalSeconds
    }

    return $removed
}

# ---------------------------------------------------------------------------
# Region: Azure AD Test Group Management
# ---------------------------------------------------------------------------

function Initialize-IntuneTestGroup
{
    <#
    .SYNOPSIS
        Connects to Microsoft Graph, creates a test security group, and adds
        the current device as a member for assignment testing.
    .OUTPUTS
        [hashtable] with keys: GroupId, SkipReason.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$ClientSecret
    )

    $result = @{
        GroupId = $null
        SkipReason = $null
    }

    # Install and import required Graph modules.
    $requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.DirectoryManagement')
    $missing = $requiredModules | Where-Object { -not (Get-Module -Name $_ -ListAvailable) }
    if ($missing)
    {
        Write-Information "Installing missing Graph modules: $($missing -join ', ')" -InformationAction Continue
        Install-Module -Name $missing -Force -Scope CurrentUser
    }
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement

    $secureSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($ClientId, $secureSecret)
    $deviceName = $env:COMPUTERNAME

    try
    {
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $credential -NoWelcome -ErrorAction Stop

        # Remove existing test group if present.
        $testGroupName = "PSADT Test Group $deviceName"
        $existingGroups = Get-MgGroup -Filter "displayName eq '$testGroupName'" -ErrorAction Stop
        foreach ($g in $existingGroups)
        {
            Write-Information "Removing existing group '$testGroupName' (Id: $($g.Id))" -InformationAction Continue
            Remove-MgGroup -GroupId $g.Id -ErrorAction Stop
            Start-Sleep -Seconds 5
        }

        # Create a fresh security group.
        $group = New-MgGroup -BodyParameter @{
            displayName = $testGroupName
            securityEnabled = $true
            mailEnabled = $false
            mailNickname = [System.Guid]::NewGuid().Guid
        } -ErrorAction Stop
        $result.GroupId = $group.Id
        Write-Information "Created test group '$testGroupName' with ObjectId: $($result.GroupId)" -InformationAction Continue

        # Wait for group to propagate.
        $maxWait = 20; $waited = 0
        while ($waited -lt $maxWait)
        {
            if (Get-MgGroup -GroupId $result.GroupId -ErrorAction SilentlyContinue) { break }
            Write-Information "Waiting for group to propagate... ($waited s)" -InformationAction Continue
            Start-Sleep -Seconds 5
            $waited += 5
        }
        if ($waited -ge $maxWait)
        {
            throw "Group '$testGroupName' did not propagate within $maxWait seconds."
        }

        # Add current device as a member.
        $device = Get-MgDevice -Filter "displayName eq '$deviceName'" -ErrorAction Stop | Select-Object -First 1
        if (-not $device)
        {
            Write-Information "Unable to find a Microsoft Graph device with displayName '$deviceName'." -InformationAction Continue
        }
        else
        {
            $addMaxRetries = 6
            $addRetry = 0
            while ($true)
            {
                try
                {
                    New-MgGroupMember -GroupId $result.GroupId -DirectoryObjectId $device.Id -ErrorAction Stop
                    break
                }
                catch
                {
                    $addRetry++
                    if ($addRetry -ge $addMaxRetries -or $_.Exception.Message -notmatch 'ResourceNotFound') { throw }
                    Write-Information "Member add failed (ResourceNotFound), retrying... ($addRetry/$addMaxRetries)" -InformationAction Continue
                    Start-Sleep -Seconds 5
                }
            }
            Write-Information "Added device '$deviceName' (Id: $($device.Id)) to group '$testGroupName'." -InformationAction Continue
        }
    }
    catch
    {
        $result.SkipReason = "Azure AD group setup failed: $($_.Exception.Message)"
        Write-Warning "[Intune] Skipping group-assignment tests: $($_.Exception.Message)"
    }

    return $result
}

# ---------------------------------------------------------------------------
# Region: MSI Utilities
# ---------------------------------------------------------------------------

function Get-MsiProductCode
{
    <#
    .SYNOPSIS
        Reads the ProductCode from an MSI file using the WindowsInstaller COM object.
    .OUTPUTS
        The ProductCode string.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$MsiPath
    )

    $comObj = New-Object -ComObject WindowsInstaller.Installer
    $db = $comObj.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $comObj, @($MsiPath, 0))
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='ProductCode'"))
    $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    return [string]($record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1)))
}

function Get-IntuneWinAppUtilPath
{
    <#
    .SYNOPSIS
        Returns the path to IntuneWinAppUtil.exe if it exists at the default location.
    #>
    $toolPath = 'C:\Tools\Intune\IntuneWinAppUtil.exe'
    if (Test-Path $toolPath)
    {
        return $toolPath
    }
    return $null
}

#pragma warning restore PSPlaceOpenBrace
