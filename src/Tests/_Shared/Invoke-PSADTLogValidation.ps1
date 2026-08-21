function Invoke-PsadtLogValidation
{
    <#
    .SYNOPSIS
        Validates the PSADT log exit code after deployment for both V3 and V4 apps.
    .DESCRIPTION
        Resolves SessionProperties from:
        - V4: the app's template parameter file (New-ADTTemplate.params.ps1)
        - V3: parsed directly from Deploy-Application.ps1 variable declarations
        Constructs the expected InstallName and log file path, then checks the
        finalization line for a success/reboot exit code.
    .OUTPUTS
        [hashtable] with keys: Success, ExitCode, LogFile, Message, Skipped.
    #>
    param (
        [Parameter(Mandatory)]
        [hashtable]$App,

        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Uninstall', 'Repair')]
        [string]$DeploymentType
    )

    $testsRoot = Split-Path -Path $PSScriptRoot -Parent

    # Resolve SessionProperties based on template version.
    $sessionProps = $null
    if ($App.TemplateVersion -eq 'V4')
    {
        $templateParamsPath = Join-Path $testsRoot "V4\$($App.AppFolderName)\New-ADTTemplate.params.ps1"
        if (-not (Test-Path -LiteralPath $templateParamsPath -PathType Leaf))
        {
            return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $null; Message = "Template parameter file not found: $templateParamsPath" }
        }

        . $templateParamsPath

        if (-not (Get-Variable -Name NewADTTemplateParameters -Scope Local -ErrorAction Ignore))
        {
            return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $null; Message = "Variable `$NewADTTemplateParameters not found in [$templateParamsPath]." }
        }

        $templateParams = (Get-Variable -Name NewADTTemplateParameters -Scope Local).Value
        if ($null -eq $templateParams -or $templateParams -isnot [System.Collections.IDictionary])
        {
            return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $null; Message = "Invalid `$NewADTTemplateParameters in [$templateParamsPath]." }
        }

        $sessionProps = $templateParams['SessionProperties']
    }
    elseif ($App.TemplateVersion -eq 'V3')
    {
        # Parse session properties directly from the V3 Deploy-Application.ps1.
        $v3ScriptPath = Join-Path $testsRoot "V3\$($App.AppFolderName)\Deploy-Application.ps1"
        if (-not (Test-Path -LiteralPath $v3ScriptPath -PathType Leaf))
        {
            return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $null; Message = "V3 script not found: $v3ScriptPath" }
        }

        $scriptContent = Get-Content -LiteralPath $v3ScriptPath -Raw
        $sessionProps = @{
            AppSuccessExitCodes = @(0)
            AppRebootExitCodes  = @(1641, 3010)
        }
        $varMap = @{
            'appVendor'   = 'AppVendor'
            'appName'     = 'AppName'
            'appVersion'  = 'AppVersion'
            'appArch'     = 'AppArch'
            'appLang'     = 'AppLang'
            'appRevision' = 'AppRevision'
        }
        foreach ($varName in $varMap.Keys)
        {
            if ($scriptContent -match "(?m)^\s*\[String\]\`$$varName\s*=\s*'([^']*)'")
            {
                $sessionProps[$varMap[$varName]] = $Matches[1]
            }
        }

        # Verify we got all required fields.
        $missing = @('AppVendor', 'AppName', 'AppVersion', 'AppArch', 'AppLang', 'AppRevision') | Where-Object { -not $sessionProps.ContainsKey($_) }
        if ($missing)
        {
            return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $null; Message = "Could not parse V3 variables from [$v3ScriptPath]: missing $($missing -join ', ')." }
        }
    }

    if ($null -eq $sessionProps -or $sessionProps -isnot [System.Collections.IDictionary])
    {
        return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $null; Message = "SessionProperties not found or invalid for app [$($App.Name)]." }
    }

    # Construct InstallName the same way PSADT does (spaces removed, double underscores collapsed, trimmed).
    $appVendor = ($sessionProps.AppVendor) -replace '\s', ''
    $appName = ($sessionProps.AppName) -replace '\s', ''
    $appVersion = $sessionProps.AppVersion
    $appArch = $sessionProps.AppArch
    $appLang = $sessionProps.AppLang
    $appRevision = $sessionProps.AppRevision

    $installName = "${appVendor}_${appName}_${appVersion}_${appArch}_${appLang}_${appRevision}" -replace '__+', '_'
    $installName = $installName.Trim('_')

    # Default log path: C:\Windows\Logs\Software
    $logPath = "$env:SystemRoot\Logs\Software"
    $logFilePattern = "${installName}_*_${DeploymentType}.log"

    $logFiles = Get-ChildItem -Path $logPath -Filter $logFilePattern -File -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending

    if (-not $logFiles)
    {
        Write-Warning "[$($App.Name)] Log validation FAILED: No log file matching [$logFilePattern] found in [$logPath]."
        return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $null; Message = "Log file not found matching [$logFilePattern] in [$logPath]." }
    }

    $logFile = $logFiles[0]
    # Read the full log so validation can find the expected result even when
    # multiple PSADT sessions are appended to the same file.
    $logContent = Get-Content -LiteralPath $logFile.FullName -Raw -ErrorAction SilentlyContinue

    # Pattern: [InstallName] install completed in [X] seconds with exit code [N].
    $exitCodePattern = [regex]::Escape($installName) + '\].*completed in \[.*\] seconds with exit code \[(\d+)\]'
    if ($logContent -match $exitCodePattern)
    {
        $exitCode = [int]$Matches[1]
        $successCodes = @($sessionProps.AppSuccessExitCodes) + @($sessionProps.AppRebootExitCodes)
        if ($exitCode -in $successCodes)
        {
            Write-Information "[$($App.Name)] Log validation PASSED: [$($logFile.Name)] - $DeploymentType exit code [$exitCode]." -InformationAction Continue
            return @{ Success = $true; Skipped = $false; ExitCode = $exitCode; LogFile = $logFile.FullName; Message = "Exit code $exitCode is a success/reboot code." }
        }
        else
        {
            Write-Warning "[$($App.Name)] Log validation FAILED: [$($logFile.Name)] - $DeploymentType exit code [$exitCode] not in success codes."
            return @{ Success = $false; Skipped = $false; ExitCode = $exitCode; LogFile = $logFile.FullName; Message = "Exit code $exitCode is not in success/reboot codes." }
        }
    }
    else
    {
        Write-Warning "[$($App.Name)] Log validation FAILED: [$($logFile.Name)] - Finalization exit code line not found."
        $errorSummary = Get-PsadtLogErrorSummary -LogFilePath $logFile.FullName
        $msg = "Finalization exit code line not found in log."
        if ($errorSummary) { $msg += " $errorSummary" }
        return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $logFile.FullName; Message = $msg }
    }
}

function Get-PsadtForceCountdownDeferralExpectation
{
    param (
        [Parameter(Mandatory)]
        [hashtable]$App
    )

    $result = @{
        Expected = $false
        DeferTimes = $null
        ForceCountdown = $null
        TemplateParamsPath = $null
        Message = $null
    }

    if ($App.TemplateVersion -ne 'V4')
    {
        return $result
    }

    $testsRoot = Split-Path -Path $PSScriptRoot -Parent
    $templateParamsPath = Join-Path $testsRoot "V4\$($App.AppFolderName)\New-ADTTemplate.params.ps1"
    $result.TemplateParamsPath = $templateParamsPath
    if (-not (Test-Path -LiteralPath $templateParamsPath -PathType Leaf))
    {
        $result.Message = "Template parameter file not found: $templateParamsPath"
        return $result
    }

    Remove-Variable -Name NewADTTemplateParameters -Scope Local -ErrorAction SilentlyContinue
    . $templateParamsPath

    if (-not (Get-Variable -Name NewADTTemplateParameters -Scope Local -ErrorAction Ignore))
    {
        $result.Message = "Variable `$NewADTTemplateParameters not found in [$templateParamsPath]."
        return $result
    }

    $templateParams = (Get-Variable -Name NewADTTemplateParameters -Scope Local).Value
    if ($null -eq $templateParams -or $templateParams -isnot [System.Collections.IDictionary] -or -not $templateParams.PreInstallScriptBlock)
    {
        $result.Message = "Invalid or missing PreInstallScriptBlock in [$templateParamsPath]."
        return $result
    }

    $preInstallScriptText = $templateParams.PreInstallScriptBlock.ToString()
    $deferTimesMatch = [System.Text.RegularExpressions.Regex]::Match($preInstallScriptText, '(?m)^\s*DeferTimes\s*=\s*(?<Value>\d+)')
    $forceCountdownMatch = [System.Text.RegularExpressions.Regex]::Match($preInstallScriptText, '(?m)^\s*ForceCountdown\s*=\s*(?<Value>\d+)')
    if ($deferTimesMatch.Success)
    {
        $result.DeferTimes = $deferTimesMatch.Groups['Value'].Value
    }
    if ($forceCountdownMatch.Success)
    {
        $result.ForceCountdown = $forceCountdownMatch.Groups['Value'].Value
    }

    $hasForceCloseProcessesCountdown = $preInstallScriptText.Contains('ForceCloseProcessesCountdown')
    $result.Expected = ($null -ne $result.DeferTimes) -and ($null -ne $result.ForceCountdown) -and -not $hasForceCloseProcessesCountdown
    return $result
}

function Test-PsadtForceCountdownDeferralLog
{
    param (
        [Parameter(Mandatory)]
        [hashtable]$App,

        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Uninstall', 'Repair')]
        [string]$DeploymentType
    )

    $expectation = Get-PsadtForceCountdownDeferralExpectation -App $App
    if (-not $expectation.Expected)
    {
        return @{ Success = $false; Skipped = $false; LogFile = $null; Message = "ForceCountdown deferral is not expected for app [$($App.Name)]. $($expectation.Message)" }
    }

    $logValidation = Invoke-PsadtLogValidation -App $App -DeploymentType $DeploymentType
    if (-not $logValidation.LogFile)
    {
        return @{ Success = $false; Skipped = $false; LogFile = $null; Message = $logValidation.Message }
    }

    $logContent = Get-Content -LiteralPath $logValidation.LogFile -Raw -ErrorAction SilentlyContinue
    $failures = @()
    if ($logContent -notmatch 'Evaluating disk space requirements\.')
    {
        $failures += 'expected disk space requirement check line was not found'
    }
    if ($logContent -notmatch 'Successfully passed minimum disk space requirement check\.')
    {
        $failures += 'expected disk space pass line was not found'
    }

    $expectedInitialDeferralsRemaining = [int]$expectation.DeferTimes
    $expectedUpdatedDeferralsRemaining = [Math]::Max(($expectedInitialDeferralsRemaining - 1), 0)
    $expectedInitialDeferralsRemainingPattern = [System.Text.RegularExpressions.Regex]::Escape($expectedInitialDeferralsRemaining.ToString())
    $expectedUpdatedDeferralsRemainingPattern = [System.Text.RegularExpressions.Regex]::Escape($expectedUpdatedDeferralsRemaining.ToString())
    $expectedForceCountdownPattern = [System.Text.RegularExpressions.Regex]::Escape($expectation.ForceCountdown)
    if (($logContent -notmatch "The user has \[$expectedInitialDeferralsRemainingPattern\] deferrals remaining\.") -and ($logContent -notmatch "Setting deferral history: \[DeferTimesRemaining = $expectedUpdatedDeferralsRemainingPattern\]\."))
    {
        $failures += "expected deferrals remaining [$expectedInitialDeferralsRemaining] or deferral history [$expectedUpdatedDeferralsRemaining] line was not found"
    }
    if ($logContent -notmatch "Close applications countdown has \[$expectedForceCountdownPattern\] seconds remaining\.")
    {
        $failures += "expected ForceCountdown [$($expectation.ForceCountdown)]-second countdown line was not found"
    }
    if ($logContent -notmatch 'Countdown timer has elapsed and deferrals remaining\. Force deferral\.')
    {
        $failures += 'expected force deferral line was not found'
    }
    if ($logContent -notmatch "$($DeploymentType.ToLowerInvariant()) was deferred .* exit code \[1602\]")
    {
        $failures += 'expected deferred finalization with exit code 1602 was not found'
    }

    if ($failures.Count)
    {
        return @{ Success = $false; Skipped = $false; LogFile = $logValidation.LogFile; Message = ($failures -join '; ') }
    }

    return @{ Success = $true; Skipped = $false; LogFile = $logValidation.LogFile; Message = "ForceCountdown deferral log validation passed for deferrals remaining [$expectedInitialDeferralsRemaining], deferral history [$expectedUpdatedDeferralsRemaining], and ForceCountdown [$($expectation.ForceCountdown)]." }
}

function Test-PsadtForceCloseCountdownLog
{
    param (
        [Parameter(Mandatory)]
        [hashtable]$App,

        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Uninstall', 'Repair')]
        [string]$DeploymentType
    )

    if ($App.TemplateVersion -ne 'V4')
    {
        return @{ Success = $false; Skipped = $false; LogFile = $null; Message = "ForceCloseProcessesCountdown validation requires a V4 app template for app [$($App.Name)]." }
    }

    $testsRoot = Split-Path -Path $PSScriptRoot -Parent
    $templateParamsPath = Join-Path $testsRoot "V4\$($App.AppFolderName)\New-ADTTemplate.params.ps1"
    if (-not (Test-Path -LiteralPath $templateParamsPath -PathType Leaf))
    {
        return @{ Success = $false; Skipped = $false; LogFile = $null; Message = "Template parameter file not found: $templateParamsPath" }
    }

    Remove-Variable -Name NewADTTemplateParameters -Scope Local -ErrorAction SilentlyContinue
    . $templateParamsPath

    if (-not (Get-Variable -Name NewADTTemplateParameters -Scope Local -ErrorAction Ignore))
    {
        return @{ Success = $false; Skipped = $false; LogFile = $null; Message = "Variable `$NewADTTemplateParameters not found in [$templateParamsPath]." }
    }

    $templateParams = (Get-Variable -Name NewADTTemplateParameters -Scope Local).Value
    $scriptBlockName = "Pre$($DeploymentType)ScriptBlock"
    if ($null -eq $templateParams -or $templateParams -isnot [System.Collections.IDictionary] -or -not $templateParams[$scriptBlockName])
    {
        return @{ Success = $false; Skipped = $false; LogFile = $null; Message = "Invalid or missing $scriptBlockName in [$templateParamsPath]." }
    }

    $scriptBlockText = $templateParams[$scriptBlockName].ToString()
    $countdownMatch = [System.Text.RegularExpressions.Regex]::Match($scriptBlockText, '(?m)^\s*ForceCloseProcessesCountdown\s*=\s*(?<Value>\d+)')
    if (-not $countdownMatch.Success)
    {
        return @{ Success = $false; Skipped = $false; LogFile = $null; Message = "ForceCloseProcessesCountdown was not configured in $scriptBlockName for app [$($App.Name)]." }
    }

    $logValidation = Invoke-PsadtLogValidation -App $App -DeploymentType $DeploymentType
    if (-not $logValidation.LogFile)
    {
        return @{ Success = $false; Skipped = $false; LogFile = $null; Message = $logValidation.Message }
    }

    $logContent = Get-Content -LiteralPath $logValidation.LogFile -Raw -ErrorAction SilentlyContinue
    $expectedCountdown = $countdownMatch.Groups['Value'].Value
    $expectedCountdownPattern = [System.Text.RegularExpressions.Regex]::Escape($expectedCountdown)
    $failures = @()
    if ($logContent -notmatch "Close applications countdown has \[$expectedCountdownPattern\] seconds remaining\.")
    {
        $failures += "expected ForceCloseProcessesCountdown [$expectedCountdown]-second countdown line was not found"
    }
    if ($logContent -notmatch 'Close application\(s\) countdown timer has elapsed\. Force closing application\(s\)\.')
    {
        $failures += 'expected force closing application(s) line was not found'
    }

    if ($failures.Count)
    {
        return @{ Success = $false; Skipped = $false; LogFile = $logValidation.LogFile; Message = ($failures -join '; ') }
    }

    return @{ Success = $true; Skipped = $false; LogFile = $logValidation.LogFile; Message = "ForceCloseProcessesCountdown log validation passed for countdown [$expectedCountdown]." }
}

function Test-PsadtAppFileVersion
{
    param (
        [Parameter(Mandatory)]
        [hashtable]$App,

        [Parameter(Mandatory)]
        [ValidateSet('Install', 'Deferral')]
        [string]$ExpectedState
    )

    $filePath = $App.VersionCheckFilePath
    $pattern = if ($ExpectedState -eq 'Deferral') { $App.ExpectedDeferralFileVersionPattern } else { $App.ExpectedInstallFileVersionPattern }
    $description = if ($ExpectedState -eq 'Deferral') { $App.ExpectedDeferralFileVersionDescription } else { $App.ExpectedInstallFileVersionDescription }

    if ([string]::IsNullOrWhiteSpace($filePath) -or [string]::IsNullOrWhiteSpace($pattern))
    {
        return @{ Success = $true; Skipped = $true; FilePath = $filePath; FileVersion = $null; Message = "No file version expectation configured for app [$($App.Name)] state [$ExpectedState]." }
    }

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf))
    {
        return @{ Success = $false; Skipped = $false; FilePath = $filePath; FileVersion = $null; Message = "Expected version check file not found: $filePath" }
    }

    $fileVersion = (Get-Item -LiteralPath $filePath).VersionInfo.FileVersion
    if ($fileVersion -match $pattern)
    {
        return @{ Success = $true; Skipped = $false; FilePath = $filePath; FileVersion = $fileVersion; Message = "File version [$fileVersion] matched expected $ExpectedState version [$description]." }
    }

    return @{ Success = $false; Skipped = $false; FilePath = $filePath; FileVersion = $fileVersion; Message = "File version [$fileVersion] did not match expected $ExpectedState version [$description] using pattern [$pattern]." }
}

# ---------------------------------------------------------------------------
# Region: PSADT Log Parsing
# ---------------------------------------------------------------------------

function Get-PsadtLogErrorSummary
{
    <#
    .SYNOPSIS
        Parses a PSADT CMTrace-format log file and extracts a concise summary
        of all error-level (type="3") entries.
    .DESCRIPTION
        Handles both single-line and multi-line CMTrace log entries.
        Single-line: <![LOG[message]LOG]!><time="..." type="3" ...>
        Multi-line:  <![LOG[line1\nline2\n...]LOG]!><time="..." type="3" ...>
        (where ]LOG]!> and metadata appear on the final line of the entry)
    .OUTPUTS
        [string] A summary of error messages, or $null if no errors found.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$LogFilePath
    )

    if (-not (Test-Path -LiteralPath $LogFilePath -PathType Leaf))
    {
        return $null
    }

    $logLines = Get-Content -LiteralPath $LogFilePath -ErrorAction SilentlyContinue
    if (-not $logLines) { return $null }

    $errorMessages = @()
    $inEntry = $false
    $entryBuffer = $null

    foreach ($line in $logLines)
    {
        if (-not $inEntry)
        {
            # Detect start of a new PSADT session - reset error collection to only keep errors from the last run.
            if ($line -match '<!\[LOG\[\[Initialization\]' -or $line -match '\[Initialization\] ::')
            {
                $errorMessages = @()
            }

            # Single-line entry: both <![LOG[ and ]LOG]!> on same line with type="3".
            if ($line -match 'type="3"' -and $line -match '<!\[LOG\[(.+?)\]LOG\]!>')
            {
                $errorMessages += $Matches[1].Trim()
            }
            # Start of multi-line entry: <![LOG[ without ]LOG]!> on this line.
            elseif ($line -match '<!\[LOG\[(.*)$' -and $line -notmatch '\]LOG\]!>')
            {
                $inEntry = $true
                $entryBuffer = $Matches[1]
            }
        }
        else
        {
            # End of multi-line entry: line contains ]LOG]!> with metadata.
            if ($line -match '^(.*?)\]LOG\]!>')
            {
                $tailPart = $Matches[1]
                $inEntry = $false

                # Check if this entry is type="3".
                if ($line -match 'type="3"')
                {
                    $msg = ($entryBuffer + ' ' + $tailPart).Trim()
                    if ($msg) { $errorMessages += $msg }
                }
                $entryBuffer = $null
            }
            else
            {
                # Middle of multi-line entry.
                $entryBuffer += ' ' + $line.Trim()
            }
        }
    }

    if (-not $errorMessages) { return $null }

    # Take the last 3 unique errors (chronologically most recent), truncate for report.
    $maxMsgLen = 600
    $reversed = @($errorMessages)
    [array]::Reverse($reversed)
    $seen = @{}
    $recent = @()
    foreach ($msg in $reversed)
    {
        if (-not $seen.ContainsKey($msg))
        {
            $seen[$msg] = $true
            $recent += $msg
            if ($recent.Count -ge 3) { break }
        }
    }
    [array]::Reverse($recent)
    $trimmed = $recent | ForEach-Object {
        if ($_.Length -gt $maxMsgLen) { $_.Substring(0, $maxMsgLen) + '...' } else { $_ }
    }
    return "Errors: $($trimmed -join ' | ')"
}
