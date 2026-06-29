[CmdletBinding()]
param
(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]$DeploymentType,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]$DeployMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$SuppressRebootPassThru,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$TerminalServerMode,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.SwitchParameter]$DisableLogging
)

$templateParamsPath = Join-Path $PSScriptRoot "..\..\V4\Notepad++\New-ADTTemplate.params.ps1"
$templateRunnerPath = Join-Path $PSScriptRoot "..\..\V4\_Shared\Invoke-ADTTemplateRunner.ps1"

if (-not (Test-Path -LiteralPath $templateParamsPath -PathType Leaf))
{
    throw "Template params script not found at path: $templateParamsPath"
}
if (-not (Test-Path -LiteralPath $templateRunnerPath -PathType Leaf))
{
    throw "Template runner script not found at path: $templateRunnerPath"
}

. $templateParamsPath
. $templateRunnerPath

if (-not ($NewADTTemplateParameters -is [System.Collections.IDictionary]))
{
    throw "`$NewADTTemplateParameters is missing or invalid in [$templateParamsPath]."
}

$files = [System.Collections.Generic.List[System.String]]::new()
foreach ($filePath in @($NewADTTemplateParameters['Files']))
{
    if (-not [System.String]::IsNullOrWhiteSpace([string]$filePath))
    {
        $files.Add([string]$filePath)
    }
}

if ($files.Count -eq 0)
{
    throw "No valid Files entries were found in [$templateParamsPath]."
}

$invokeParams = @{
    TemplatefilePath = $templateParamsPath
    DestinationPath = [string]$NewADTTemplateParameters['Destination']
    Files = $files
}

if ($NewADTTemplateParameters.Contains('SupportFiles') -and $null -ne $NewADTTemplateParameters['SupportFiles'])
{
    $supportFiles = [System.Collections.Generic.List[System.String]]::new()
    foreach ($supportFilePath in @($NewADTTemplateParameters['SupportFiles']))
    {
        if (-not [System.String]::IsNullOrWhiteSpace([string]$supportFilePath))
        {
            $supportFiles.Add([string]$supportFilePath)
        }
    }
    if ($supportFiles.Count -gt 0)
    {
        $invokeParams.SupportFiles = $supportFiles
    }
}

Invoke-ADTTemplateRunner @invokeParams
exit $LASTEXITCODE
