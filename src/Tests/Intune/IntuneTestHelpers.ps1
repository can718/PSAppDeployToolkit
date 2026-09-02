#pragma warning disable PSPlaceOpenBrace

[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
param()

$sharedLogValidationPath = Join-Path $PSScriptRoot '..\_Shared\Invoke-PSADTLogValidation.ps1'
if (-not (Test-Path -LiteralPath $sharedLogValidationPath -PathType Leaf))
{
    throw "Required shared helper file not found: $sharedLogValidationPath"
}
. $sharedLogValidationPath

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
        Enabled     = $false
        AccessToken = $null
        TestRunId   = $env:TEST_RUN_ID
        ApiBaseUrl  = $env:TERRAFORGE_API_BASE_URL
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
# Region: Unified Template Package Preparation
# ---------------------------------------------------------------------------
function New-IntuneTestWorkDir
{
    <#
    .SYNOPSIS
        Unified entry point that dispatches to V3 or V4 work directory preparation
        based on the app configuration hashtable.
    .OUTPUTS
        [hashtable] with keys: WorkDir, FilesDir.
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable]$App,

        [Parameter(Mandatory)]
        [string]$BasePath
    )

    if ($App.TemplateVersion -eq 'V3')
    {
        $runnerScript = Join-Path $PSScriptRoot "..\V3\$($App.AppFolderName)\Deploy-Application.ps1"
        return New-IntuneTestWorkDirV3 `
            -AppFolderName       $App.AppFolderName `
            -BasePath            $BasePath `
            -InstallerSourceFile $App.InstallerSourceFile `
            -RunnerScriptPath    $runnerScript
    }
    else
    {
        $templateParamsPath = Join-Path $PSScriptRoot "..\V4\$($App.AppFolderName)\New-ADTTemplate.params.ps1"
        return New-IntuneTestWorkDirV4 `
            -AppFolderName      $App.AppFolderName `
            -BasePath           $BasePath `
            -TemplateParamsPath $templateParamsPath
    }
}

# ---------------------------------------------------------------------------
# Region: V3 Template Package Preparation
# ---------------------------------------------------------------------------
function New-IntuneTestWorkDirV3
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
        [string]$InstallerSourceFile,

        [Parameter(Mandatory)]
        [string]$RunnerScriptPath
    )

    $workDir = Join-Path $BasePath $AppFolderName
    New-Item -Path $workDir -ItemType Directory -Force | Out-Null

    # Step 1: Copy PSADT v3 template
    $v3Path = $env:PSADT_TEMPLATE_V3_DIR
    if (-not (Test-Path $v3Path))
    {
        throw "PSADT v3 template folder missing: $v3Path"
    }
    Copy-Item -Path (Join-Path $v3Path '*') -Destination $workDir -Recurse -Force
    Write-Information "[$AppFolderName] Copied PSADT template from '$v3Path' to '$workDir'." -InformationAction Continue

    # Step 2: Copy installer files
    $filesDir = Join-Path $workDir 'Files'
    if (-not (Test-Path $filesDir))
    {
        New-Item -Path $filesDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $InstallerSourceFile))
    {
        throw "Installer file not found: '$InstallerSourceFile'."
    }
    Copy-Item -Path $InstallerSourceFile -Destination $filesDir -Force
    Write-Information "[$AppFolderName] Copied installer '$([System.IO.Path]::GetFileName($InstallerSourceFile))' to '$filesDir'." -InformationAction Continue

    # Step 3: Copy runner script into work directory without renaming.
    Copy-Item -Path $RunnerScriptPath -Destination $workDir -Force
    Write-Information "[$AppFolderName] Copied runner script '$([System.IO.Path]::GetFileName($RunnerScriptPath))' to '$workDir'." -InformationAction Continue

    return @{
        WorkDir  = $workDir
        FilesDir = $filesDir
    }
}

# ---------------------------------------------------------------------------
# Region: V4 Template Package Preparation
# ---------------------------------------------------------------------------

function New-IntuneTestWorkDirV4
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
        [string]$TemplateParamsPath
    )

    $workDir = Join-Path $BasePath $AppFolderName
    if (Test-Path -LiteralPath $workDir)
    {
        Remove-Item -Path $workDir -Recurse -Force
    }

    $templateRunnerPath = Join-Path $PSScriptRoot '..\_Shared\Invoke-ADTTemplateRunner.ps1'
    if (-not (Test-Path -LiteralPath $templateRunnerPath -PathType Leaf))
    {
        throw "Template runner file not found: $templateRunnerPath"
    }
    if (-not (Test-Path -LiteralPath $TemplateParamsPath -PathType Leaf))
    {
        throw "Template parameter file not found: $TemplateParamsPath"
    }

    $v4TemplatePath = $env:PSADT_TEMPLATE_V4_DIR
    if ([string]::IsNullOrWhiteSpace($v4TemplatePath) -or -not (Test-Path -LiteralPath $v4TemplatePath -PathType Container))
    {
        throw "PSADT_TEMPLATE_V4_DIR is missing or invalid: $v4TemplatePath"
    }

    $psadtManifestPath = Get-ChildItem -Path $v4TemplatePath -Filter 'PSAppDeployToolkit.psd1' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($psadtManifestPath))
    {
        throw "Unable to find PSAppDeployToolkit.psd1 under PSADT_TEMPLATE_V4_DIR: $v4TemplatePath"
    }

    Import-Module -FullyQualifiedName $psadtManifestPath -Force -ErrorAction Stop

    . $templateRunnerPath
    . $TemplateParamsPath

    if (-not (Get-Variable -Name NewADTTemplateParameters -Scope Local -ErrorAction Ignore))
    {
        throw "Variable `$NewADTTemplateParameters was not found after loading [$TemplateParamsPath]."
    }

    $templateParams = (Get-Variable -Name NewADTTemplateParameters -Scope Local).Value
    if ($null -eq $templateParams -or $templateParams -isnot [System.Collections.IDictionary])
    {
        throw "Variable `$NewADTTemplateParameters in [$TemplateParamsPath] is not a hashtable/dictionary."
    }

    $filesValue = $templateParams['Files']
    if ($null -eq $filesValue)
    {
        throw "Template parameter file [$TemplateParamsPath] does not define a non-null [Files] value."
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
        throw "Template parameter file [$TemplateParamsPath] did not resolve any valid [Files] entries."
    }

    $invokeTemplateParams = @{
        TemplatefilePath = $TemplateParamsPath
        DestinationPath  = $BasePath
        Name             = $AppFolderName
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

    $resolvedPackageRoot = if (Test-Path -LiteralPath (Join-Path $workDir 'Invoke-AppDeployToolkit.ps1') -PathType Leaf)
    {
        $workDir
    }
    else
    {
        (Get-ChildItem -Path $workDir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Invoke-AppDeployToolkit.ps1') -PathType Leaf } | Select-Object -First 1 -ExpandProperty FullName)
    }
    if ([string]::IsNullOrWhiteSpace($resolvedPackageRoot))
    {
        $resolvedPackageRoot = $workDir
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

        Copy-Item -Path $recordingModuleSource -Destination (Join-Path $recordingDir 'PSAppDeployToolkit.Recording.psm1') -Force
        if (Test-Path -LiteralPath $recordingManifestSource -PathType Leaf)
        {
            Copy-Item -Path $recordingManifestSource -Destination (Join-Path $recordingDir 'PSAppDeployToolkit.Recording.psd1') -Force
        }
    }

    $filesDir = Join-Path $resolvedPackageRoot 'Files'
    if (-not (Test-Path -LiteralPath $filesDir -PathType Container))
    {
        throw "Files directory was not created by template generation: $filesDir"
    }

    Write-Information "[$AppFolderName] Generated package from V4 template params '$TemplateParamsPath' into '$resolvedPackageRoot'." -InformationAction Continue

    return @{
        WorkDir  = $resolvedPackageRoot
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
    $setupBaseName = [System.IO.Path]::GetFileNameWithoutExtension($SetupFileName)
    $intunewinFile = Join-Path $WorkDir "$setupBaseName.intunewin"
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
        DisplayName   = $displayName
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
        $win32App = Get-IntuneWin32App -DisplayName $DisplayName -Verbose | Sort-Object -Property createdDateTime -Descending | Select-Object -First 1
        $retryCount++
    }

    return $win32App
}

# ---------------------------------------------------------------------------
# Region: Parallel Poll with Retry
# ---------------------------------------------------------------------------

function Invoke-ParallelAppPollWithRetry
{
    <#
    .SYNOPSIS
        Runs parallel ThreadJob polls for app installation or uninstallation
        with a configurable retry loop. Handles MDM sync and IME restart
        between retry attempts.
    .OUTPUTS
        [hashtable] with keys: Succeeded (string[]), Failed (string[]).
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable]$UploadedApps,

        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Uninstall')]
        [string]$Operation,

        [Parameter(Mandatory)]
        [string]$HelperScriptPath,

        [string[]]$AppNames,

        [string[]]$NoRetryAppNames,

        [int]$MaxRetryCount = 1
    )

    if (-not (Test-Path -LiteralPath $HelperScriptPath))
    {
        throw "HelperScriptPath not found: $HelperScriptPath"
    }

    if (-not $AppNames)
    {
        $AppNames = @($UploadedApps.Keys)
    }

    $waitFunction = if ($Operation -eq 'Install') { 'Wait-AppInstallation' } else { 'Wait-AppUninstallation' }

    # Initial poll.
    $jobs = foreach ($appName in $AppNames)
    {
        $appInfo = $UploadedApps[$appName]
        $displayName = $appInfo.RegDisplayName
        $valueName = $appInfo.RegVersionName
        $expectedValue = $appInfo.RegVersionValue
        Start-ThreadJob -Name "$Operation-$appName" -ScriptBlock {
            . $using:HelperScriptPath
            & $using:waitFunction -DisplayName $using:displayName -ValueName $using:valueName -ExpectedValue $using:expectedValue -SkipImeRestartAndSync
        }
    }

    Write-Information "Waiting for $($jobs.Count) parallel $($Operation.ToLower()) polls..." -InformationAction Continue
    $jobs | Wait-Job | Out-Null

    $succeededApps = @()
    $appsToCheck = @($AppNames)

    for ($attempt = 0; $attempt -le $MaxRetryCount; $attempt++)
    {
        if ($appsToCheck)
        {
            if ($attempt -gt 0)
            {
                Write-Information "[Parallel $Operation] Retry attempt $attempt for failed apps: $($appsToCheck -join ', ')" -InformationAction Continue

                Invoke-MdmSync
                Start-Sleep -Seconds 8
                Wait-IntuneManagementExtension

                $retryJobs = foreach ($appName in $appsToCheck)
                {
                    $appInfo = $UploadedApps[$appName]
                    $displayName = $appInfo.RegDisplayName
                    $valueName = $appInfo.RegVersionName
                    $expectedValue = $appInfo.RegVersionValue
                    Start-ThreadJob -Name "${Operation}Retry$attempt-$appName" -ScriptBlock {
                        . $using:HelperScriptPath
                        & $using:waitFunction -DisplayName $using:displayName -ValueName $using:valueName -ExpectedValue $using:expectedValue -SkipImeRestartAndSync
                    }
                }

                Write-Information "Waiting for $($retryJobs.Count) retry $($Operation.ToLower()) polls..." -InformationAction Continue
                $retryJobs | Wait-Job | Out-Null
            }

            $nextFailedApps = @()
            foreach ($appName in $appsToCheck)
            {
                $jobName = if ($attempt -eq 0) { "$Operation-$appName" } else { "${Operation}Retry$attempt-$appName" }
                $jobResult = Get-Job -Name $jobName -ErrorAction SilentlyContinue | Receive-Job
                if ($jobResult -ne $true)
                {
                    Write-Information "[$appName] $Operation poll result (attempt $attempt): $jobResult" -InformationAction Continue
                    if ($NoRetryAppNames -contains $appName)
                    {
                        Write-Information "[$appName] $Operation poll failed as expected; skipping retry." -InformationAction Continue
                    }
                    else
                    {
                        $nextFailedApps += $appName
                    }
                }
                else
                {
                    if (-not ($succeededApps -contains $appName))
                    {
                        $succeededApps += $appName
                    }
                }
            }

            if ($attempt -gt 0)
            {
                $retryJobs | Remove-Job -Force
            }
            else
            {
                $jobs | Remove-Job -Force
            }

            $appsToCheck = @($nextFailedApps)
        }
    }

    Write-Information "[Parallel $Operation] Succeeded: $(if ($succeededApps) { $succeededApps -join ', ' } else { 'none' })" -InformationAction Continue
    Write-Information "[Parallel $Operation] Failed: $(if ($appsToCheck) { $appsToCheck -join ', ' } else { 'none' })" -InformationAction Continue

    return @{
        Succeeded = $succeededApps
        Failed    = @($appsToCheck)
    }
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

    while (-not $installed -and $waited -le $MaxWaitSeconds)
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
        }
        elseif ($waited -lt $MaxWaitSeconds)
        {
            Write-Information "Waiting for IntuneManagementExtension... ($($waited + $PollIntervalSeconds) / $MaxWaitSeconds s elapsed)" -InformationAction Continue
            Start-Sleep -Seconds $PollIntervalSeconds
            $waited += $PollIntervalSeconds
        }
        else
        {
            $waited += $PollIntervalSeconds
        }
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

function Wait-PsadtForceCountdownDeferralLog
{
    param (
        [Parameter(Mandatory)]
        [hashtable]$App,

        [int]$MaxWaitSeconds = 900,

        [int]$PollIntervalSeconds = 60
    )

    $waited = 0
    while ($waited -lt $MaxWaitSeconds)
    {
        $logValidation = Test-PsadtForceCountdownDeferralLog -App $App -DeploymentType 'Install'
        if ($logValidation.Success)
        {
            Write-Information "[$($App.Name)] ForceCountdown deferral log detected after $waited s." -InformationAction Continue
            return $true
        }

        if (-not $logValidation.LogFile)
        {
            Write-Information "[$($App.Name)] No PSADT log exists yet; triggering another MDM sync." -InformationAction Continue
            Invoke-MdmSync
        }

        Write-Information "[$($App.Name)] ForceCountdown deferral log not ready; waiting $PollIntervalSeconds s... ($($waited + $PollIntervalSeconds) / $MaxWaitSeconds s elapsed)" -InformationAction Continue
        Start-Sleep -Seconds $PollIntervalSeconds
        $waited += $PollIntervalSeconds
    }

    return $false
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
        [int]$SyncIntervalSeconds = 300,
        [switch]$SkipImeRestartAndSync
    )

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $waited = 0
    $verified = $false
    $nextSyncAt = 0

    Write-Information "Polling for '$DisplayName' installation (DisplayName='$DisplayName', timeout: $($MaxWaitSeconds / 60) min)..." -InformationAction Continue
    while (-not $verified -and $waited -lt $MaxWaitSeconds)
    {
        foreach ($root in $uninstallRoots)
        {
            $subKeys = Get-ChildItem -Path $root -ErrorAction SilentlyContinue
            foreach ($subKey in $subKeys)
            {
                $props = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
                $displayNameMatched = $props -and (($props.DisplayName -eq $DisplayName) -or ($props.DisplayName -like "$DisplayName*"))
                $actualValue = if ($props) { $props.$ValueName } else { $null }
                $versionMatched = $actualValue -eq $ExpectedValue -or $actualValue -like "$ExpectedValue*"
                if (-not $verified -and $displayNameMatched -and $versionMatched)
                {
                    $verified = $true
                    Write-Information "'$DisplayName' detected in registry after $waited s (path: $($subKey.PSPath))." -InformationAction Continue
                    Write-Information "[Succeed] '$DisplayName' installation verification successful." -InformationAction Continue
                }
            }
        }

        # Trigger MDM sync and restart IME at regular intervals to accelerate install.
        if (-not $verified -and -not $SkipImeRestartAndSync -and $waited -ge $nextSyncAt)
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

        if (-not $verified)
        {
            Write-Information "'$DisplayName' not yet installed; waiting $PollIntervalSeconds s... ($($waited + $PollIntervalSeconds) / $MaxWaitSeconds s elapsed)" -InformationAction Continue
            Start-Sleep -Seconds $PollIntervalSeconds
            $waited += $PollIntervalSeconds
        }
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
        [int]$SyncIntervalSeconds = 300,
        [switch]$SkipImeRestartAndSync
    )

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $waited = 0
    $removed = $false
    $nextSyncAt = 0

    Write-Information "Polling for '$DisplayName' uninstallation (DisplayName='$DisplayName', timeout: $($MaxWaitSeconds / 60) min)..." -InformationAction Continue
    while (-not $removed -and $waited -lt $MaxWaitSeconds)
    {
        $found = $false
        foreach ($root in $uninstallRoots)
        {
            $subKeys = Get-ChildItem -Path $root -ErrorAction SilentlyContinue
            foreach ($subKey in $subKeys)
            {
                $props = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
                $displayNameMatched = $props -and (($props.DisplayName -eq $DisplayName) -or ($props.DisplayName -like "$DisplayName*"))
                if (-not $found -and $displayNameMatched -and $props.$ValueName -eq $ExpectedValue)
                {
                    $found = $true
                }
            }
        }

        if (-not $found)
        {
            $removed = $true
            Write-Information "'$DisplayName' no longer detected in registry after $waited s." -InformationAction Continue
            Write-Information "[Succeed] '$DisplayName' uninstallation verification successful." -InformationAction Continue
        }

        # Trigger MDM sync and restart IME at regular intervals to accelerate uninstall.
        if (-not $removed -and -not $SkipImeRestartAndSync -and $waited -ge $nextSyncAt)
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

        if (-not $removed)
        {
            Write-Information "'$DisplayName' still installed; waiting $PollIntervalSeconds s... ($($waited + $PollIntervalSeconds) / $MaxWaitSeconds s elapsed)" -InformationAction Continue
            Start-Sleep -Seconds $PollIntervalSeconds
            $waited += $PollIntervalSeconds
        }
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
        [string]$ClientSecret,

        [string]$ExistingGroupId
    )

    $result = @{
        GroupId    = $null
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

        if (-not [System.String]::IsNullOrWhiteSpace($ExistingGroupId))
        {
            $existingGroup = Get-MgGroup -GroupId $ExistingGroupId -ErrorAction Stop
            $result.GroupId = $existingGroup.Id
            Write-Information "Reusing Azure AD test group with ObjectId: $($result.GroupId)" -InformationAction Continue
            return $result
        }

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
            displayName     = $testGroupName
            securityEnabled = $true
            mailEnabled     = $false
            mailNickname    = [System.Guid]::NewGuid().Guid
        } -ErrorAction Stop
        $result.GroupId = $group.Id
        Write-Information "Created test group '$testGroupName' with ObjectId: $($result.GroupId)" -InformationAction Continue

        # Wait for group to propagate.
        $maxWait = 20; $waited = 0
        $groupAvailable = $false
        while (-not $groupAvailable -and $waited -lt $maxWait)
        {
            $groupAvailable = $null -ne (Get-MgGroup -GroupId $result.GroupId -ErrorAction SilentlyContinue)
            if (-not $groupAvailable)
            {
                Write-Information "Waiting for group to propagate... ($waited s)" -InformationAction Continue
                Start-Sleep -Seconds 5
                $waited += 5
            }
        }
        if (-not $groupAvailable)
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
            $memberAdded = $false
            while (-not $memberAdded -and $addRetry -lt $addMaxRetries)
            {
                try
                {
                    New-MgGroupMember -GroupId $result.GroupId -DirectoryObjectId $device.Id -ErrorAction Stop
                    $memberAdded = $true
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

function Get-IntunePsExecPath
{
    <#
    .SYNOPSIS
        Returns the path to PsExec.exe, downloading PSTools when it is not cached locally.
    #>
    param (
        [string]$ToolsDirectory = 'C:\Tools\Intune\PSTools',

        [string]$DownloadUri = 'https://download.sysinternals.com/files/PSTools.zip',

        [string]$LogPrefix = 'Intune'
    )

    $psExecPath = Join-Path $ToolsDirectory 'PsExec.exe'
    if (Test-Path -LiteralPath $psExecPath -PathType Leaf)
    {
        Write-Information "[$LogPrefix] Reusing PsExec from '$psExecPath'." -InformationAction Continue
        return $psExecPath
    }

    New-Item -Path $ToolsDirectory -ItemType Directory -Force | Out-Null
    $downloadPath = Join-Path $ToolsDirectory 'PSTools.zip'

    Write-Information "[$LogPrefix] PsExec not found at '$psExecPath'. Downloading PSTools from '$DownloadUri'." -InformationAction Continue
    Invoke-WebRequest -Uri $DownloadUri -OutFile $downloadPath -UseBasicParsing
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $ToolsDirectory -Force

    if (-not (Test-Path -LiteralPath $psExecPath -PathType Leaf))
    {
        throw "[$LogPrefix] PsExec.exe was not found after extracting '$downloadPath' to '$ToolsDirectory'."
    }

    return $psExecPath
}

function Get-IntuneActiveInteractiveSessionId
{
    <#
    .SYNOPSIS
        Returns the active interactive Windows session ID, or $null when none is found.
    #>
    param (
        [string]$LogPrefix = 'Intune'
    )

    try
    {
        $queryUserOutput = & "$env:SystemRoot\System32\quser.exe" 2>$null
        foreach ($line in @($queryUserOutput | Select-Object -Skip 1))
        {
            $match = [System.Text.RegularExpressions.Regex]::Match([string]$line, '^\s*>?\s*(?<UserName>\S+)\s+(?:(?<SessionName>\S+)\s+)?(?<SessionId>\d+)\s+(?<State>Active)\b')
            if ($match.Success)
            {
                $sessionId = [int]$match.Groups['SessionId'].Value
                $sessionName = $match.Groups['SessionName'].Value
                Write-Information "[$LogPrefix] Active interactive session detected: User=[$($match.Groups['UserName'].Value)], SessionName=[$sessionName], SessionId=[$sessionId]." -InformationAction Continue
                return $sessionId
            }
        }
    }
    catch
    {
        Write-Information "[$LogPrefix] Unable to query active interactive session via quser.exe: $($_.Exception.Message)" -InformationAction Continue
    }

    Write-Information "[$LogPrefix] No active interactive session detected." -InformationAction Continue
    return $null
}

function Start-IntuneSystemProcess
{
    <#
    .SYNOPSIS
        Starts a process as NT AUTHORITY\SYSTEM using PsExec for Intune tests.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string]$ArgumentList,

        [string]$ProcessName,

        [int]$InteractiveSessionId = 0,

        [string]$PsExecPath,

        [string]$LogPrefix = 'Intune',

        [int]$ProcessStartWaitSeconds = 3,

        [switch]$StopExistingProcess
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf))
    {
        throw "[$LogPrefix] SYSTEM launch path not found: $FilePath"
    }

    if ([System.String]::IsNullOrWhiteSpace($PsExecPath))
    {
        $PsExecPath = Get-IntunePsExecPath -LogPrefix $LogPrefix
    }
    elseif (-not (Test-Path -LiteralPath $PsExecPath -PathType Leaf))
    {
        throw "[$LogPrefix] PsExec path not found: $PsExecPath"
    }

    if ($StopExistingProcess -and -not [System.String]::IsNullOrWhiteSpace($ProcessName))
    {
        $existingProcesses = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        if ($existingProcesses.Count -gt 0)
        {
            Write-Information "[$LogPrefix] Stopping $($existingProcesses.Count) existing '$ProcessName' process(es) before SYSTEM launch." -InformationAction Continue
            $existingProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    $psExecArguments = [System.Collections.Generic.List[string]]::new()
    $psExecArguments.Add('-accepteula')
    $psExecArguments.Add('-nobanner')
    $psExecArguments.Add('-s')
    $psExecArguments.Add('-d')
    if ($InteractiveSessionId -ge 0)
    {
        $psExecArguments.Add('-i')
        $psExecArguments.Add($InteractiveSessionId.ToString())
    }
    $psExecArguments.Add(('"{0}"' -f $FilePath))
    if (-not [System.String]::IsNullOrWhiteSpace($ArgumentList))
    {
        $psExecArguments.Add($ArgumentList)
    }

    Write-Information "[$LogPrefix] Starting '$FilePath' as SYSTEM using PsExec '$PsExecPath'." -InformationAction Continue
    $process = Start-Process -FilePath $PsExecPath -ArgumentList $psExecArguments -Wait -NoNewWindow -PassThru
    if ($process.ExitCode -ne 0)
    {
        throw "[$LogPrefix] PsExec failed to start '$FilePath' as SYSTEM. ExitCode=[$($process.ExitCode)]."
    }

    if (-not [System.String]::IsNullOrWhiteSpace($ProcessName))
    {
        Start-Sleep -Seconds $ProcessStartWaitSeconds
        $startedProcesses = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
        if ($InteractiveSessionId -ge 0)
        {
            $startedProcesses = @($startedProcesses | Where-Object { $_.SessionId -eq $InteractiveSessionId })
        }

        if ($startedProcesses.Count -eq 0)
        {
            $sessionScope = if ($InteractiveSessionId -ge 0) { " in session [$InteractiveSessionId]" } else { '' }
            throw "[$LogPrefix] Process '$ProcessName' was not running$sessionScope after SYSTEM launch of '$FilePath'."
        }

        foreach ($startedProcess in $startedProcesses)
        {
            Write-Information "[$LogPrefix] SYSTEM-launched process detected: Name=[$($startedProcess.ProcessName)], PID=[$($startedProcess.Id)], SessionId=[$($startedProcess.SessionId)], Path=[$($startedProcess.Path)]." -InformationAction Continue
        }
    }
}

#pragma warning restore PSPlaceOpenBrace
