function Import-PSADTTestCaseIdMap
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptRoot
    )

    $mapPath = Join-Path $ScriptRoot '..\_Shared\TestCaseMap.psd1'
    if (-not (Test-Path -LiteralPath $mapPath -PathType Leaf))
    {
        throw "Required test case map file not found: $mapPath"
    }

    return (Import-PowerShellDataFile -LiteralPath $mapPath)
}

function Resolve-PSADTTestCaseId
{
    param (
        [hashtable]$TestCaseIdMap,
        [string]$TestMethod
    )

    if ([string]::IsNullOrWhiteSpace($TestMethod) -or $TestMethod -notmatch '^\[(?<TestArea>INTUNE|MCM):(?<TestKey>[^\]]+)\]')
    {
        return '0'
    }

    $testArea = $Matches.TestArea
    $testKey = $Matches.TestKey
    if (-not $TestCaseIdMap -or -not $TestCaseIdMap.ContainsKey($testArea))
    {
        return '0'
    }

    $areaMap = $TestCaseIdMap[$testArea]
    if (-not $areaMap -or -not $areaMap.ContainsKey($testKey))
    {
        return '0'
    }

    return [string]$areaMap[$testKey]
}