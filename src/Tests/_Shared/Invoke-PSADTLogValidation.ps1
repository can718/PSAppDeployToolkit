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
    # Read the last portion of the log to find the finalization line with exit code.
    $logContent = Get-Content -LiteralPath $logFile.FullName -Tail 50 -ErrorAction SilentlyContinue | Out-String

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
        $lastLines = Get-Content -LiteralPath $logFile.FullName -Tail 3 -ErrorAction SilentlyContinue
        Write-Warning "[$($App.Name)] Log validation FAILED: [$($logFile.Name)] - Finalization exit code line not found."
        if ($lastLines)
        {
            Write-Warning "[$($App.Name)] Last 3 lines of log:"
            $lastLines | ForEach-Object { Write-Warning "  $_" }
        }
        $tailMsg = if ($lastLines) { "`n" + ($lastLines -join "`n") } else { '' }
        return @{ Success = $false; Skipped = $false; ExitCode = $null; LogFile = $logFile.FullName; Message = "Finalization exit code line not found in log.$tailMsg" }
    }
}