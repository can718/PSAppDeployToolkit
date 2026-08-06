param(
    [Parameter(Mandatory = $true)]
    [string]$TrxFilePath,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "$(Get-Location)\TestResults\test-report.html"
)

function Convert-TrxToHtml {
    param(
        [string]$TrxPath,
        [string]$HtmlPath
    )

    if (-not (Test-Path $TrxPath)) {
        Write-Error "TRX file not found: $TrxPath"
        return
    }

    # Read and parse TRX file
    [xml]$trxContent = Get-Content $TrxPath -Encoding UTF8

    # Extract test run information
    $testRun = $trxContent.TestRun
    $runName = $testRun.name
    $runUser = $testRun.runUser
    $startTime = [DateTime]::Parse($testRun.Times.start)
    $finishTime = [DateTime]::Parse($testRun.Times.finish)
    $duration = $finishTime - $startTime

    # Extract test result statistics
    $counters = $testRun.ResultSummary.Counters
    $total = [int]$counters.total
    $passed = [int]$counters.passed
    $failed = [int]$counters.failed
    # $skipped = if ($counters.notExecuted -and $counters.notExecuted -ne '') { [int]$counters.notExecuted } else { 0 }

    # $errors = [int]$counters.error
    # $timeout = [int]$counters.timeout
    # $aborted = [int]$counters.aborted
    # $inconclusive = [int]$counters.inconclusive

    $passRate = if ($total -gt 0) { [math]::Round(($passed / $total) * 100, 2) } else { 0 }
    $outcome = $testRun.ResultSummary.outcome

    # Get all test results
    $testResults = @()
    if ($testRun.Results.UnitTestResult) {
        foreach ($result in $testRun.Results.UnitTestResult) {
            $errorInfo = $null
            $stdOutText = ""
            $errorMessage = ""
            $stackTrace = ""
            if ($result.Output) {
                $errorInfoProperty = $result.Output.PSObject.Properties['ErrorInfo']
                if ($errorInfoProperty) {
                    $errorInfo = $errorInfoProperty.Value
                }

                $stdOutProperty = $result.Output.PSObject.Properties['StdOut']
                if ($stdOutProperty -and $null -ne $stdOutProperty.Value) {
                    $stdOutText = [string]$stdOutProperty.Value
                }
            }

            if ($errorInfo) {
                $messageProperty = $errorInfo.PSObject.Properties['Message']
                if ($messageProperty -and $null -ne $messageProperty.Value) {
                    $errorMessage = [string]$messageProperty.Value
                }

                $stackTraceProperty = $errorInfo.PSObject.Properties['StackTrace']
                if ($stackTraceProperty -and $null -ne $stackTraceProperty.Value) {
                    $stackTrace = [string]$stackTraceProperty.Value
                }
            }

            $testResults += [PSCustomObject]@{
                TestName     = $result.testName
                Outcome      = $result.outcome
                Duration     = $result.duration
                StartTime    = [DateTime]::Parse($result.startTime)
                EndTime      = [DateTime]::Parse($result.endTime)
                ErrorMessage = $errorMessage
                StackTrace   = $stackTrace
                StdOut       = $stdOutText
            }
        }
    }

    $skippedTests = $testResults | Where-Object { $_.Outcome -eq "NotExecuted" -or $_.Outcome -eq "Skipped" }
    $skipped = if ($skippedTests -and $skippedTests.Count -gt 0) { $skippedTests.Count } else { 0 }

    # Additional fallback: if still 0, try to calculate from total - passed - failed
    if ($skipped -eq 0 -and $total -gt 0 -and $passed -ge 0 -and $failed -ge 0) {
        $calculatedSkipped = $total - $passed - $failed
        if ($calculatedSkipped -gt 0) {
            $skipped = $calculatedSkipped
        }
    }

    # Get test definition information (for categorization)
    $testCategories = @{}
    if ($testRun.TestDefinitions.UnitTest) {
        foreach ($testDef in $testRun.TestDefinitions.UnitTest) {
            $testName = $testDef.name
            $categories = @()
            if ($testDef.TestCategory.TestCategoryItem) {
                foreach ($category in $testDef.TestCategory.TestCategoryItem) {
                    $categories += $category.TestCategory
                }
            }
            $testCategories[$testName] = $categories
        }
    }

    # Generate HTML content
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Test Report - $runName</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #1b2e51ff 0%, #2a5298 100%);
            min-height: 100vh;
            padding: 20px;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            overflow: hidden;
        }

        .header {
            background: linear-gradient(135deg, #1336ca 0%, #107772 50%, #4f2ca4 100%);
            color: white;
            padding: 30px;
            text-align: center;
        }

        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }

        .header .subtitle {
            font-size: 1.2em;
            opacity: 0.9;
        }

        .summary {
            display: grid;
            grid-template-columns: repeat(7, 1fr);
            gap: 15px;
            padding: 30px;
            background: #f8f9fa;
        }

        .summary-card {
            background: white;
            border-radius: 10px;
            padding: 20px;
            text-align: center;
            box-shadow: 0 5px 15px rgba(0,0,0,0.1);
            transition: transform 0.3s ease;
        }

        .summary-card:hover {
            transform: translateY(-5px);
        }

        .summary-card h3 {
            color: #2c3e50;
            margin-bottom: 10px;
            font-size: 1.1em;
        }

        .summary-card .value {
            font-size: 2.5em;
            font-weight: bold;
            margin-bottom: 5px;
        }

        .passed .value { color: #27ae60; }
        .failed .value { color: #e74c3c; }
        .skipped .value { color: #f39c12; }
        .total .value { color: #3498db; }
        .rate .value { color: #9b59b6; }
        .duration .value { color: #17a2b8; }
        .outcome .value { color: #e67e22; }

        .progress-bar {
            width: 100%;
            height: 20px;
            background: #ecf0f1;
            border-radius: 10px;
            overflow: hidden;
            margin: 20px 0;
        }

        .progress-fill {
            height: 100%;
            background: linear-gradient(90deg, #27ae60, #2ecc71);
            border-radius: 10px;
            transition: width 0.5s ease;
        }

        .test-results {
            padding: 30px;
        }

        .test-results h2 {
            color: #2c3e50;
            margin-bottom: 20px;
            font-size: 1.8em;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
        }

        .test-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
            margin-bottom: 20px;
            background: white;
            border-radius: 10px;
            overflow: hidden;
            box-shadow: 0 5px 15px rgba(0,0,0,0.1);
        }

        .test-table th {
            background: linear-gradient(135deg, #3498db, #2980b9);
            color: white;
            padding: 15px;
            text-align: left;
            font-weight: 600;
        }

        .test-table td {
            padding: 12px 15px;
            border-bottom: 1px solid #ecf0f1;
        }

        .test-table tr:hover {
            background: #f8f9fa;
        }

        .status {
            padding: 5px 12px;
            border-radius: 20px;
            font-weight: bold;
            text-transform: uppercase;
            font-size: 0.8em;
        }

        .status.passed {
            background: #d5f4e6;
            color: #27ae60;
        }

        .status.failed {
            background: #fadbd8;
            color: #e74c3c;
        }

        .status.skipped {
            background: #fff3cd;
            color: #f39c12;
        }

        .error-details {
            margin-top: 10px;
            padding: 10px;
            background: #fff5f5;
            border-left: 4px solid #e74c3c;
            border-radius: 5px;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            color: #c0392b;
        }

        .success-details {
            margin-top: 10px;
            padding: 10px;
            background: #f0f9f0;
            border-left: 4px solid #27ae60;
            border-radius: 5px;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
            color: #27ae60;
        }

        .categories {
            display: flex;
            gap: 5px;
            flex-wrap: wrap;
        }

        .category-tag {
            background: #3498db;
            color: white;
            padding: 2px 8px;
            border-radius: 12px;
            font-size: 0.8em;
        }

        .footer {
            background: #2c3e50;
            color: white;
            text-align: center;
            padding: 20px;
            font-size: 0.9em;
        }

        .collapsible {
            cursor: pointer;
            user-select: none;
        }

        .collapsible:hover {
            background: #f0f0f0;
        }

        .content {
            max-height: 0;
            overflow: hidden;
            transition: max-height 0.3s ease;
        }

        .content.active {
            max-height: 500px;
            padding-bottom: 12px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1><i class="fas fa-flask"></i> Test Execution Report</h1>
            <div class="subtitle">$runName</div>
            <div style="margin-top: 10px; font-size: 0.9em;">
                User: $runUser | Start Time: $($startTime.ToString("yyyy-MM-dd HH:mm:ss"))
            </div>
        </div>

        <div class="summary">
            <div class="summary-card total">
                <h3>Total Tests</h3>
                <div class="value">$total</div>
            </div>
            <div class="summary-card passed">
                <h3>Passed</h3>
                <div class="value">$passed</div>
            </div>
            <div class="summary-card failed">
                <h3>Failed</h3>
                <div class="value">$failed</div>
            </div>
            <div class="summary-card skipped">
                <h3>Skipped</h3>
                <div class="value">$skipped</div>
            </div>
            <div class="summary-card rate">
                <h3>Pass Rate</h3>
                <div class="value">$passRate%</div>
            </div>
            <div class="summary-card duration">
                <h3>Duration</h3>
                <div class="value">$($duration.TotalSeconds.ToString("F1"))s</div>
            </div>
            <div class="summary-card outcome">
                <h3>Overall</h3>
                <div class="value">$(if($outcome -eq "Passed" -or $outcome -eq "Completed"){"<i class='fas fa-check-circle' style='color: #27ae60;'></i>"}elseif($outcome -eq "Failed"){"<i class='fas fa-times-circle' style='color: #e74c3c;'></i>"}else{"<i class='fas fa-exclamation-triangle' style='color: #f39c12;'></i>"})</div>
            </div>
        </div>

        <div style="padding: 0 30px;">
            <div class="progress-bar">
                <div class="progress-fill" style="width: $passRate%"></div>
            </div>
        </div>

        <div class="test-results">
            <div class="filters" style="margin-bottom: 20px; padding: 20px; background: #f8f9fa; border-radius: 10px; border: 1px solid #dee2e6;">
                <h3 style="margin-bottom: 15px; color: #2c3e50;"><i class="fas fa-search"></i> Filter Tests</h3>
                <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px;">
                    <div>
                        <input type="text" id="nameFilter" placeholder="Search by test name..." style="width: 100%; padding: 8px; border: 1px solid #ccc; border-radius: 5px;">
                    </div>
                    <div>
                        <select id="statusFilter" style="width: 100%; padding: 8px; border: 1px solid #ccc; border-radius: 5px;">
                            <option value="">All Statuses</option>
                            <option value="Passed">Passed</option>
                            <option value="Failed">Failed</option>
                            <option value="NotExecuted">Skipped</option>
                        </select>
                    </div>
                    <div>
                        <select id="categoryFilter" style="width: 100%; padding: 8px; border: 1px solid #ccc; border-radius: 5px;">
                            <option value="">All Categories</option>
                        </select>
                    </div>
                    <div style="display: flex; align-items: end;">
                        <button onclick="clearFilters()" style="padding: 10px 16px; background: linear-gradient(135deg, rgb(92 146 175), rgb(128 195 189)); color: white; border: none; border-radius: 5px; cursor: pointer; width: 100%; transition: all 0.3s ease; box-shadow: 0 2px 4px rgba(0,0,0,0.1);" onmouseover="this.style.transform='translateY(-2px)'; this.style.boxShadow='0 4px 8px rgba(0,0,0,0.15)'" onmouseout="this.style.transform='translateY(0)'; this.style.boxShadow='0 2px 4px rgba(0,0,0,0.1)'">Reset</button>
                    </div>
                </div>
            </div>
"@

    # Separate failed, passed, and skipped tests (ensure they are arrays)
    $failedTests = @($testResults | Where-Object { $_.Outcome -eq "Failed" })
    $passedTests = @($testResults | Where-Object { $_.Outcome -eq "Passed" })
    $skippedTests = @($testResults | Where-Object { $_.Outcome -eq "NotExecuted" -or $_.Outcome -eq "Skipped" })

    # Generate failed tests table
    if ($failedTests.Count -gt 0) {
        $html += @"
            <h2><i class="fas fa-times-circle" style="color: #e74c3c;"></i> Failed Tests ($($failedTests.Count))</h2>
            <table class="test-table">
                <thead>
                    <tr>
                        <th>Test Name</th>
                        <th>Status</th>
                        <th>Category</th>
                        <th>Duration</th>
                        <th>Details</th>
                    </tr>
                </thead>
                <tbody>
"@

        foreach ($test in $failedTests) {
            $statusClass = $test.Outcome.ToLower()
            $statusIcon = "<i class='fas fa-times'></i>"
            $durationMs = if ($test.Duration) { [TimeSpan]::Parse($test.Duration).TotalMilliseconds } else { 0 }
            $testIndex = [array]::IndexOf($testResults, $test)

            $categories = if ($testCategories[$test.TestName]) {
                ($testCategories[$test.TestName] | ForEach-Object { "<span class='category-tag'>$_</span>" }) -join " "
            }
            else {
                "<span class='category-tag'>Uncategorized</span>"
            }

            $categoryValues = if ($testCategories[$test.TestName]) {
                ($testCategories[$test.TestName] -join ",")
            }
            else {
                "Uncategorized"
            }

            $html += @"
                    <tr class="collapsible test-row" onclick="toggleContent('content-$testIndex')"
                        data-test-name="$($test.TestName)"
                        data-status="$($test.Outcome)"
                        data-categories="$categoryValues">
                        <td><strong>$($test.TestName)</strong></td>
                        <td><span class="status $statusClass">$statusIcon $($test.Outcome)</span></td>
                        <td>$categories</td>
                        <td>$($durationMs.ToString("F0"))ms</td>
                        <td>$(if($test.ErrorMessage -or $test.StdOut){"<i class='fas fa-file-alt'></i> Click to view"}else{"None"})</td>
                    </tr>
"@

            if ($test.ErrorMessage -or $test.StdOut) {
                $html += @"
                    <tr>
                        <td colspan="5" style="padding: 0px 15px;">
                            <div class="content" id="content-$testIndex">
                                <div class="error-details">
"@
                if ($test.ErrorMessage) {
                    $html += "<strong>Error Message:</strong><br>$($test.ErrorMessage -replace "`n", "<br>"))<br><br>"
                }
                if ($test.StackTrace) {
                    $html += "<strong>Stack Trace:</strong><br>$($test.StackTrace -replace "`n", "<br>")<br><br>"
                }
                if ($test.StdOut) {
                    $html += "<strong>Output:</strong><br>$($test.StdOut -replace "`n", "<br>")"
                }
                $html += @"
                                </div>
                            </div>
                        </td>
                    </tr>
"@
            }
        }

        $html += @"
                </tbody>
            </table>
"@
    }

    # Generate passed tests table
    if ($passedTests.Count -gt 0) {
        $html += @"
            <h2><i class="fas fa-check-circle" style="color: #27ae60;"></i> Passed Tests ($($passedTests.Count))</h2>
            <table class="test-table">
                <thead>
                    <tr>
                        <th>Test Name</th>
                        <th>Status</th>
                        <th>Category</th>
                        <th>Duration</th>
                        <th>Details</th>
                    </tr>
                </thead>
                <tbody>
"@

        foreach ($test in $passedTests) {
            $statusClass = $test.Outcome.ToLower()
            $statusIcon = "<i class='fas fa-check'></i>"
            $durationMs = if ($test.Duration) { [TimeSpan]::Parse($test.Duration).TotalMilliseconds } else { 0 }
            $testIndex = [array]::IndexOf($testResults, $test)

            $categories = if ($testCategories[$test.TestName]) {
                ($testCategories[$test.TestName] | ForEach-Object { "<span class='category-tag'>$_</span>" }) -join " "
            }
            else {
                "<span class='category-tag'>Uncategorized</span>"
            }

            $categoryValues = if ($testCategories[$test.TestName]) {
                ($testCategories[$test.TestName] -join ",")
            }
            else {
                "Uncategorized"
            }

            $html += @"
                    <tr class="collapsible test-row" onclick="toggleContent('content-$testIndex')"
                        data-test-name="$($test.TestName)"
                        data-status="$($test.Outcome)"
                        data-categories="$categoryValues">
                        <td><strong>$($test.TestName)</strong></td>
                        <td><span class="status $statusClass">$statusIcon $($test.Outcome)</span></td>
                        <td>$categories</td>
                        <td>$($durationMs.ToString("F0"))ms</td>
                        <td>$(if($test.ErrorMessage -or $test.StdOut){"<i class='fas fa-file-alt'></i> Click to view"}else{"None"})</td>
                    </tr>
"@

            if ($test.ErrorMessage -or $test.StdOut) {
                $html += @"
                    <tr>
                        <td colspan="5" style="padding: 0px 15px;">
                            <div class="content" id="content-$testIndex">
                                <div class="success-details">
"@
                if ($test.ErrorMessage) {
                    $html += "<strong>Message:</strong><br>$($test.ErrorMessage -replace "`n", "<br>"))<br><br>"
                }
                if ($test.StackTrace) {
                    $html += "<strong>Stack Trace:</strong><br>$($test.StackTrace -replace "`n", "<br>")<br><br>"
                }
                if ($test.StdOut) {
                    $html += "<strong>Output:</strong><br>$($test.StdOut -replace "`n", "<br>")"
                }
                $html += @"
                                </div>
                            </div>
                        </td>
                    </tr>
"@
            }
        }

        $html += @"
                </tbody>
            </table>
"@
    }

    # Generate skipped tests table
    if ($skippedTests.Count -gt 0) {
        $html += @"
            <h2><i class="fas fa-exclamation-triangle" style="color: #f39c12;"></i> Skipped Tests ($($skippedTests.Count))</h2>
            <table class="test-table">
                <thead>
                    <tr>
                        <th>Test Name</th>
                        <th>Status</th>
                        <th>Category</th>
                        <th>Duration</th>
                        <th>Details</th>
                    </tr>
                </thead>
                <tbody>
"@

        foreach ($test in $skippedTests) {
            $statusClass = "skipped"
            $statusIcon = "<i class='fas fa-exclamation-triangle'></i>"
            $durationMs = if ($test.Duration) { [TimeSpan]::Parse($test.Duration).TotalMilliseconds } else { 0 }
            $testIndex = [array]::IndexOf($testResults, $test)

            $categories = if ($testCategories[$test.TestName]) {
                ($testCategories[$test.TestName] | ForEach-Object { "<span class='category-tag'>$_</span>" }) -join " "
            }
            else {
                "<span class='category-tag'>Uncategorized</span>"
            }

            $categoryValues = if ($testCategories[$test.TestName]) {
                ($testCategories[$test.TestName] -join ",")
            }
            else {
                "Uncategorized"
            }

            $html += @"
                    <tr class="collapsible test-row" onclick="toggleContent('content-$testIndex')"
                        data-test-name="$($test.TestName)"
                        data-status="$($test.Outcome)"
                        data-categories="$categoryValues">
                        <td><strong>$($test.TestName)</strong></td>
                        <td><span class="status $statusClass">$statusIcon Skipped</span></td>
                        <td>$categories</td>
                        <td>$($durationMs.ToString("F0"))ms</td>
                        <td>$(if($test.ErrorMessage -or $test.StdOut){"<i class='fas fa-file-alt'></i> Click to view"}else{"None"})</td>
                    </tr>
"@

            if ($test.ErrorMessage -or $test.StdOut) {
                $html += @"
                    <tr>
                        <td colspan="5" style="padding: 0px 15px;">
                            <div class="content" id="content-$testIndex">
                                <div class="error-details">
"@
                if ($test.ErrorMessage) {
                    $html += "<strong>Message:</strong><br>$($test.ErrorMessage -replace "`n", "<br>")<br><br>"
                }
                if ($test.StackTrace) {
                    $html += "<strong>Stack Trace:</strong><br>$($test.StackTrace -replace "`n", "<br>")<br><br>"
                }
                if ($test.StdOut) {
                    $html += "<strong>Output:</strong><br>$($test.StdOut -replace "`n", "<br>")"
                }
                $html += @"
                                </div>
                            </div>
                        </td>
                    </tr>
"@
            }
        }

        $html += @"
                </tbody>
            </table>
"@
    }

    $html += @"
        </div>

        <div class="footer">
            <p>Report Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Automatically generated by Terraforge Automation Tests</p>
        </div>
    </div>

    <script>
        function toggleContent(contentId) {
            var content = document.getElementById(contentId);
            if (content.classList.contains('active')) {
                content.classList.remove('active');
            } else {
                content.classList.add('active');
            }
        }

        function populateCategoryFilter() {
            var categoryFilter = document.getElementById('categoryFilter');
            var categories = new Set();

            var testRows = document.querySelectorAll('.test-row');
            testRows.forEach(function(row) {
                var rowCategories = row.getAttribute('data-categories');
                if (rowCategories) {
                    rowCategories.split(',').forEach(function(cat) {
                        categories.add(cat.trim());
                    });
                }
            });

            categories.forEach(function(category) {
                var option = document.createElement('option');
                option.value = category;
                option.textContent = category;
                categoryFilter.appendChild(option);
            });
        }

        function filterTests() {
            var nameFilter = document.getElementById('nameFilter').value.toLowerCase();
            var statusFilter = document.getElementById('statusFilter').value;
            var categoryFilter = document.getElementById('categoryFilter').value;

            var testRows = document.querySelectorAll('.test-row');
            var visibleCount = 0;
            var totalCount = testRows.length;

            testRows.forEach(function(row) {
                var testName = row.getAttribute('data-test-name').toLowerCase();
                var testStatus = row.getAttribute('data-status');
                var testCategories = row.getAttribute('data-categories');
                var nextRow = row.nextElementSibling;

                var nameMatch = nameFilter === '' || testName.includes(nameFilter);
                var statusMatch = statusFilter === '' || testStatus === statusFilter;
                var categoryMatch = categoryFilter === '' || testCategories.includes(categoryFilter);

                if (nameMatch && statusMatch && categoryMatch) {
                    row.style.display = '';
                    if (nextRow && nextRow.querySelector('.content')) {
                        nextRow.style.display = '';
                    }
                    visibleCount++;
                } else {
                    row.style.display = 'none';
                    if (nextRow && nextRow.querySelector('.content')) {
                        nextRow.style.display = 'none';
                    }
                }
            });
        }

        function clearFilters() {
            document.getElementById('nameFilter').value = '';
            document.getElementById('statusFilter').value = '';
            document.getElementById('categoryFilter').value = '';
            filterTests();
        }

        // Auto expand failed tests
        window.onload = function() {
            // Populate category filter
            populateCategoryFilter();

            // Add event listeners for filters
            document.getElementById('nameFilter').addEventListener('input', filterTests);
            document.getElementById('statusFilter').addEventListener('change', filterTests);
            document.getElementById('categoryFilter').addEventListener('change', filterTests);

            // Auto expand failed tests
            var failedTests = document.querySelectorAll('.status.failed');
            failedTests.forEach(function(test) {
                var row = test.closest('tr');
                var nextRow = row.nextElementSibling;
                if (nextRow && nextRow.querySelector('.content')) {
                    nextRow.querySelector('.content').classList.add('active');
                }
            });

            // Initial filter update
            filterTests();
        };
    </script>
</body>
</html>
"@

    # Write HTML file
    $html | Out-File -FilePath $HtmlPath -Encoding UTF8
    Write-Host "HTML report generated: $HtmlPath" -ForegroundColor Green
}

# Execute conversion
Convert-TrxToHtml -TrxPath $TrxFilePath -HtmlPath $OutputPath
