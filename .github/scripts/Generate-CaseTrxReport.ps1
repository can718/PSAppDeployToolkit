param(
    [Parameter(Mandatory = $false)]
    [string]$InputPattern = ".\\src\\Artifacts\\TestOutput\\AdditionalTests*.xml",

    [Parameter(Mandatory = $false)]
    [string]$TrxOutputPath = ".\\src\\Artifacts\\TestOutput\\AdditionalTests-Cases.trx",

    [Parameter(Mandatory = $false)]
    [string]$HtmlOutputPath = ".\\src\\Artifacts\\TestOutput\\AdditionalTests-Cases.html"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-XmlAttributeValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlNode]$Node,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Node -and $Node.Attributes) {
        $attribute = $Node.Attributes[$Name]
        if ($attribute) {
            return [string]$attribute.Value
        }
    }

    return ''
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName,

        [Parameter(Mandatory = $true)]
        $DefaultValue
    )

    if (-not $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        return $property.Value
    }

    return $DefaultValue
}

function Convert-CaseOutcomeToTrxOutcome {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Result,

        [Parameter(Mandatory = $false)]
        [string]$Executed,

        [Parameter(Mandatory = $false)]
        [string]$Success
    )

    $resultText = [string]$Result
    $executedText = [string]$Executed
    $successText = [string]$Success

    if (-not [string]::IsNullOrWhiteSpace($resultText)) {
        switch ($resultText.Trim().ToLowerInvariant()) {
            'passed' { return 'Passed' }
            'success' { return 'Passed' }
            'failed' { return 'Failed' }
            'failure' { return 'Failed' }
            'skipped' { return 'NotExecuted' }
            'inconclusive' { return 'NotExecuted' }
            default { return 'NotExecuted' }
        }
    }

    if ($executedText.Trim().ToLowerInvariant() -eq 'false') {
        return 'NotExecuted'
    }

    if ($successText.Trim().ToLowerInvariant() -eq 'true') {
        return 'Passed'
    }

    if ($successText.Trim().ToLowerInvariant() -eq 'false') {
        return 'Failed'
    }

    return 'NotExecuted'
}

function Parse-CaseDurationSeconds {
    param(
        [Parameter(Mandatory = $false)]
        [string]$DurationText
    )

    $seconds = 0.0
    [void][double]::TryParse(
        ([string]$DurationText).Trim(),
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$seconds
    )

    if ($seconds -lt 0) {
        $seconds = 0.0
    }

    return $seconds
}

function Get-TestRunTimes {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$Files
    )

    $now = Get-Date
    if (-not $Files -or $Files.Count -eq 0) {
        return [PSCustomObject]@{
            Start  = $now
            Finish = $now
        }
    }

    $start = ($Files | Measure-Object -Property LastWriteTimeUtc -Minimum).Minimum
    $finish = ($Files | Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum

    if (-not $start) { $start = $now }
    if (-not $finish) { $finish = $now }
    if ($finish -lt $start) { $finish = $start }

    return [PSCustomObject]@{
        Start  = [DateTime]::SpecifyKind([datetime]$start, [System.DateTimeKind]::Utc)
        Finish = [DateTime]::SpecifyKind([datetime]$finish, [System.DateTimeKind]::Utc)
    }
}

function Write-XmlAttribute {
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlWriter]$Writer,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $Writer.WriteAttributeString($Name, $Value)
}

$trxNamespace = 'http://microsoft.com/schemas/VisualStudio/TeamTest/2010'
$unitTestTypeId = '13cdc9d9-ddb5-4fa4-a97d-d965ccfc6d4b'
$machineId = [Environment]::MachineName

$xmlFiles = @(Get-ChildItem -Path $InputPattern -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($xmlFiles.Count -eq 0) {
    throw "No AdditionalTests XML files were found with pattern: $InputPattern"
}

$allResults = [System.Collections.Generic.List[object]]::new()

foreach ($xmlFile in $xmlFiles) {
    try {
        [xml]$xml = Get-Content -Path $xmlFile.FullName -Raw -Encoding UTF8
        $testCases = $xml.SelectNodes('/test-results/test-suite/results//test-case')

        foreach ($tc in $testCases) {
            $caseDescription = (Get-XmlAttributeValue -Node $tc -Name 'description').Trim()
            $caseNodeName = (Get-XmlAttributeValue -Node $tc -Name 'name').Trim()
            $caseName = if (-not [string]::IsNullOrWhiteSpace($caseDescription)) {
                $caseDescription
            }
            else {
                ($caseNodeName -split '\.')[-1].Trim()
            }
            if ([string]::IsNullOrWhiteSpace($caseName)) {
                $caseName = '(unnamed)'
            }

            $adoId = '0'
            if ($caseName -match '\bADO\s*[:#]?\s*(?<id>\d+)\b') {
                $adoId = [string]$Matches['id']
            }

            $result = (Get-XmlAttributeValue -Node $tc -Name 'result')
            $executed = (Get-XmlAttributeValue -Node $tc -Name 'executed')
            $success = (Get-XmlAttributeValue -Node $tc -Name 'success')
            $outcome = Convert-CaseOutcomeToTrxOutcome -Result $result -Executed $executed -Success $success

            $failureMessage = ''
            $failureNode = $tc.SelectSingleNode('failure/message')
            if ($failureNode -and -not [string]::IsNullOrWhiteSpace([string]$failureNode.InnerText)) {
                $failureMessage = [string]$failureNode.InnerText
            }
            else {
                $reasonNode = $tc.SelectSingleNode('reason/message')
                if ($reasonNode -and -not [string]::IsNullOrWhiteSpace([string]$reasonNode.InnerText)) {
                    $failureMessage = [string]$reasonNode.InnerText
                }
            }

            $durationText = (Get-XmlAttributeValue -Node $tc -Name 'duration').Trim()
            if ([string]::IsNullOrWhiteSpace($durationText)) {
                $durationText = (Get-XmlAttributeValue -Node $tc -Name 'time').Trim()
            }
            $durationSec = Parse-CaseDurationSeconds -DurationText $durationText

            $allResults.Add([PSCustomObject]@{
                AdoId        = $adoId
                Description  = $caseName
                Detail       = if ([string]::IsNullOrWhiteSpace($failureMessage)) { 'Test failed.' } else { $failureMessage }
                Outcome      = $outcome
                DurationSec  = $durationSec
                SourceFile   = $xmlFile.Name
                RawTestName  = $caseNodeName
            })
        }
    }
    catch {
        Write-Warning "Failed to parse $($xmlFile.Name): $($_.Exception.Message)"
    }
}

$total = [long]$allResults.Count
$failedCount = [long](@($allResults | Where-Object { $_.Outcome -eq 'Failed' }).Count)
$passedCount = [long](@($allResults | Where-Object { $_.Outcome -eq 'Passed' }).Count)
$notRunCount = [long](@($allResults | Where-Object { $_.Outcome -eq 'NotExecuted' }).Count)
$executedCount = [Math]::Max(0, [long]$total - [long]$notRunCount)

$aggregateSummary = [ordered]@{
    total   = $total
    passed  = $passedCount
    failed  = $failedCount
    notRun  = $notRunCount
}

$runTimes = Get-TestRunTimes -Files $xmlFiles
$runId = [guid]::NewGuid().ToString()
$testListId = [guid]::NewGuid().ToString()
$reportTime = Get-Date
$runName = "Administrator@$machineId $($reportTime.ToString('yyyy-MM-dd HH:mm:ss'))"
$runUser = "$($machineId.ToUpperInvariant())DOM\Administrator"
$runOutcome = if ([long]$aggregateSummary['failed'] -gt 0) { 'Failed' } else { 'Passed' }

$overallErrorMessage = $null
if ($runOutcome -eq 'Failed') {
    $failureMessages = [System.Collections.Generic.List[string]]::new()
    foreach ($failedResult in $allResults | Where-Object { $_.Outcome -eq 'Failed' }) {
        $adoId = [string](Get-OptionalPropertyValue -InputObject $failedResult -PropertyName 'AdoId' -DefaultValue '0')
        $description = [string](Get-OptionalPropertyValue -InputObject $failedResult -PropertyName 'Description' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($description)) {
            $description = [string](Get-OptionalPropertyValue -InputObject $failedResult -PropertyName 'RawTestName' -DefaultValue 'Playwright test')
        }
        $detail = [string](Get-OptionalPropertyValue -InputObject $failedResult -PropertyName 'Detail' -DefaultValue 'Test failed.')
        $failureMessages.Add("[ADO $adoId] $description`: $detail")
    }

    $overallErrorMessage = $failureMessages -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($overallErrorMessage)) {
        $overallErrorMessage = 'One or more tests failed.'
    }
    if ($overallErrorMessage.Length -gt 2000) {
        $overallErrorMessage = $overallErrorMessage.Substring(0, 1997) + '...'
    }
}

$trxDirectory = Split-Path -Path $TrxOutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($trxDirectory)) {
    New-Item -ItemType Directory -Path $trxDirectory -Force | Out-Null
}

$xmlSettings = [System.Xml.XmlWriterSettings]::new()
$xmlSettings.Encoding = [System.Text.UTF8Encoding]::new($false)
$xmlSettings.Indent = $true
$xmlSettings.NewLineChars = "`r`n"

$writer = [System.Xml.XmlWriter]::Create($TrxOutputPath, $xmlSettings)
try {
    $writer.WriteStartDocument()
    $writer.WriteStartElement('TestRun', $trxNamespace)
    Write-XmlAttribute -Writer $writer -Name 'id' -Value $runId
    Write-XmlAttribute -Writer $writer -Name 'name' -Value $runName
    Write-XmlAttribute -Writer $writer -Name 'runUser' -Value $runUser

    $writer.WriteStartElement('Times')
    Write-XmlAttribute -Writer $writer -Name 'creation' -Value $runTimes.Start.ToString('o')
    Write-XmlAttribute -Writer $writer -Name 'queuing' -Value $runTimes.Start.ToString('o')
    Write-XmlAttribute -Writer $writer -Name 'start' -Value $runTimes.Start.ToString('o')
    Write-XmlAttribute -Writer $writer -Name 'finish' -Value $runTimes.Finish.ToString('o')
    $writer.WriteEndElement()

    $writer.WriteStartElement('Results')
    $testResultRecords = [System.Collections.Generic.List[object]]::new()

    foreach ($testCaseResult in $allResults) {
        $executionId = [guid]::NewGuid().ToString()
        $testId = [guid]::NewGuid().ToString()
        $adoId = [string](Get-OptionalPropertyValue -InputObject $testCaseResult -PropertyName 'AdoId' -DefaultValue '0')
        $description = [string](Get-OptionalPropertyValue -InputObject $testCaseResult -PropertyName 'Description' -DefaultValue '')
        if ([string]::IsNullOrWhiteSpace($description)) {
            $description = [string](Get-OptionalPropertyValue -InputObject $testCaseResult -PropertyName 'RawTestName' -DefaultValue "ADO Test $adoId")
        }
        $detail = [string](Get-OptionalPropertyValue -InputObject $testCaseResult -PropertyName 'Detail' -DefaultValue 'No details available.')
        $outcome = [string](Get-OptionalPropertyValue -InputObject $testCaseResult -PropertyName 'Outcome' -DefaultValue 'NotExecuted')
        $durationSec = [double](Get-OptionalPropertyValue -InputObject $testCaseResult -PropertyName 'DurationSec' -DefaultValue 0)
        $sourceFile = [string](Get-OptionalPropertyValue -InputObject $testCaseResult -PropertyName 'SourceFile' -DefaultValue '')

        $testName = if ($adoId -and $adoId -ne '0') { "[$adoId] $description" } else { $description }
        $caseDuration = [TimeSpan]::FromSeconds([Math]::Max(0.0, $durationSec))
        $durationValue = '{0:hh\:mm\:ss\.fffffff}' -f $caseDuration

        $writer.WriteStartElement('UnitTestResult')
        Write-XmlAttribute -Writer $writer -Name 'executionId' -Value $executionId
        Write-XmlAttribute -Writer $writer -Name 'testId' -Value $testId
        Write-XmlAttribute -Writer $writer -Name 'testName' -Value $testName
        Write-XmlAttribute -Writer $writer -Name 'computerName' -Value $machineId
        Write-XmlAttribute -Writer $writer -Name 'testType' -Value $unitTestTypeId
        Write-XmlAttribute -Writer $writer -Name 'outcome' -Value $outcome
        Write-XmlAttribute -Writer $writer -Name 'testListId' -Value $testListId
        Write-XmlAttribute -Writer $writer -Name 'relativeResultsDirectory' -Value $executionId
        Write-XmlAttribute -Writer $writer -Name 'startTime' -Value $runTimes.Finish.ToString('o')
        Write-XmlAttribute -Writer $writer -Name 'endTime' -Value $runTimes.Finish.ToString('o')
        Write-XmlAttribute -Writer $writer -Name 'duration' -Value $durationValue

        $writer.WriteStartElement('Output')
        $writer.WriteElementString('StdOut', "Source: $sourceFile; ADO ID: $adoId")
        if ($outcome -eq 'Failed') {
            $writer.WriteStartElement('ErrorInfo')
            $writer.WriteElementString('Message', $detail)
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteEndElement()

        $testResultRecords.Add([PSCustomObject]@{
            TestId      = $testId
            ExecutionId = $executionId
        })
    }
    $writer.WriteEndElement()

    $writer.WriteStartElement('TestEntries')
    foreach ($record in $testResultRecords) {
        $writer.WriteStartElement('TestEntry')
        Write-XmlAttribute -Writer $writer -Name 'testId' -Value $record.TestId
        Write-XmlAttribute -Writer $writer -Name 'executionId' -Value $record.ExecutionId
        Write-XmlAttribute -Writer $writer -Name 'testListId' -Value $testListId
        $writer.WriteEndElement()
    }
    $writer.WriteEndElement()

    $writer.WriteStartElement('TestLists')
    $writer.WriteStartElement('TestList')
    Write-XmlAttribute -Writer $writer -Name 'name' -Value 'Results Not in a List'
    Write-XmlAttribute -Writer $writer -Name 'id' -Value $testListId
    $writer.WriteEndElement()
    $writer.WriteEndElement()

    $writer.WriteStartElement('ResultSummary')
    Write-XmlAttribute -Writer $writer -Name 'outcome' -Value $runOutcome

    $writer.WriteStartElement('Counters')
    Write-XmlAttribute -Writer $writer -Name 'total' -Value ([string]$aggregateSummary['total'])
    Write-XmlAttribute -Writer $writer -Name 'executed' -Value ([string]$executedCount)
    Write-XmlAttribute -Writer $writer -Name 'passed' -Value ([string]$aggregateSummary['passed'])
    Write-XmlAttribute -Writer $writer -Name 'failed' -Value ([string]$aggregateSummary['failed'])
    Write-XmlAttribute -Writer $writer -Name 'error' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'timeout' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'aborted' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'inconclusive' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'passedButRunAborted' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'notRunnable' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'notExecuted' -Value ([string]$aggregateSummary['notRun'])
    Write-XmlAttribute -Writer $writer -Name 'disconnected' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'warning' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'completed' -Value ([string]$executedCount)
    Write-XmlAttribute -Writer $writer -Name 'inProgress' -Value '0'
    Write-XmlAttribute -Writer $writer -Name 'pending' -Value '0'
    $writer.WriteEndElement()

    $writer.WriteStartElement('Output')
    $writer.WriteElementString(
        'StdOut',
        ([PSCustomObject]$aggregateSummary | ConvertTo-Json -Compress)
    )
    if (-not [string]::IsNullOrWhiteSpace($overallErrorMessage)) {
        # ResultSummary Output uses TestRunOutputType; capture summary failure details in StdErr.
        $writer.WriteElementString('StdErr', $overallErrorMessage)
    }
    $writer.WriteEndElement()

    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.WriteEndDocument()
}
finally {
    $writer.Dispose()
}

Write-Host "TRX report generated: $TrxOutputPath"
Write-Host "Calculated overall test status: $runOutcome"

$converterScript = Join-Path $PSScriptRoot 'Convert-TrxToHtml.ps1'
if (-not (Test-Path $converterScript -PathType Leaf)) {
    throw "TRX-to-HTML converter not found: $converterScript"
}

$pwshCommand = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
if ($pwshCommand) {
    & $pwshCommand.Source -NoProfile -File $converterScript -TrxFilePath $TrxOutputPath -OutputPath $HtmlOutputPath
}
else {
    & $converterScript -TrxFilePath $TrxOutputPath -OutputPath $HtmlOutputPath
}

if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "TRX-to-HTML conversion failed with exit code $LASTEXITCODE"
}

Write-Host "HTML report generated: $HtmlOutputPath"