[CmdletBinding()]
param
(
    [Parameter()]
    [string]$LogFolder = (Join-Path $env:TEMP 'PSADT-DeploymentLogValidation'),

    [Parameter()]
    [double]$DurationSeconds = 16.2684729,

    [Parameter()]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [string]$DeploymentType = 'Install'
)

$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

$helperScriptPath = Join-Path $PSScriptRoot 'TerraForge-AgentHelper.ps1'
. $helperScriptPath

$metadata = [ordered]@{
    AppVendor   = 'VideoLAN'
    AppName     = 'VLC media player'
    AppVersion  = '3.0.23'
    AppArch     = 'x64'
    AppLang     = 'EN'
    AppRevision = '01'
}

$rawInstallName = '{0}_{1}_{2}_{3}_{4}_{5}' -f $metadata.AppVendor, $metadata.AppName, $metadata.AppVersion, $metadata.AppArch, $metadata.AppLang, $metadata.AppRevision
$invalidPattern = '[{0}]' -f [regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
$installName = ($rawInstallName.Trim('_') -replace '\s+', '' -replace '_+', '_') -replace $invalidPattern, ''

if (-not (Test-Path -LiteralPath $LogFolder -PathType Container))
{
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}

$logFileName = '{0}_PSAppDeployToolkit_{1}.log' -f $installName, $DeploymentType
$logPath = Join-Path -Path $LogFolder -ChildPath $logFileName
$deploymentTypeText = $DeploymentType.ToLowerInvariant()

@"
[Initialization] :: Starting deployment test log.
[Finalization] :: [$installName] $deploymentTypeText completed in [$DurationSeconds] seconds with exit code [0].
"@ | Set-Content -LiteralPath $logPath -Encoding UTF8

$result = Assert-PSADTDeploymentLogContent `
    -LogFolder $LogFolder `
    -AppVendor $metadata.AppVendor `
    -AppName $metadata.AppName `
    -AppVersion $metadata.AppVersion `
    -AppArch $metadata.AppArch `
    -AppLang $metadata.AppLang `
    -AppRevision $metadata.AppRevision `
    -DeploymentType $DeploymentType `
    -PassThru

Write-Host "Generated install name: $installName"
Write-Host "Generated log path: $logPath"
$result | Format-List