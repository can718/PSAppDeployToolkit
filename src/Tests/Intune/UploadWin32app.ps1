$script:TenantID = $env:TEST_TENANTID
$script:ClientID = $env:TEST_CLIENTID
$script:ClientSecret = $env:TEST_CLIENTSECRET

if ($(Test-AccessToken) -eq $false)
{
    Write-Host "First use Connect-MSIntuneGraph to access Microsoft Graph." -ForegroundColor Yellow

    # Authenticate to Microsoft Graph
    $ClientSecret = $script:ClientSecret
    Connect-MSIntuneGraph -TenantID $script:TenantID -ClientID $script:ClientID -ClientSecret $ClientSecret
}

$IntuneWinFile = "D:\PSADTtest\Winscp\Invoke-AppDeployToolkit.intunewin"
$FileDir = Split-Path $IntuneWinFile -Parent
$PackageFile = Get-ChildItem -Path "$FileDir\Files" -File |
    Where-Object { $_.Extension -in '.msi', '.exe' } |
    Select-Object -First 1

if (-not $PackageFile)
{
    Write-Host "Can't find msi/exe files in the source folder."
    return
}
$DisplayName = $PackageFile.BaseName

# Rename .intunewin file name to match display name
$NewFileName = $PackageFile.BaseName + ".intunewin"
$NewIntuneWinFile = Join-Path -Path $FileDir -ChildPath $NewFileName
if (Test-Path $IntuneWinFile)
{
    Rename-Item -Path $IntuneWinFile -NewName $NewFileName -Force
    Write-Host "Renamed to $NewIntuneWinFile" -ForegroundColor Green
}
else
{
    Write-Host "Original intunewin file does not exist." -ForegroundColor Blue
}

if ($PackageFile.Extension -eq '.msi')
{
    try
    {
        $comObj = New-Object -ComObject WindowsInstaller.Installer
        $db = $comObj.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $comObj, @($PackageFile.FullName, 0))
        $view = $db.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $db, @("SELECT Value FROM Property WHERE Property='ProductCode'"))
        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null)
        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
        $ProductCode = $record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, 1)

        # Create MSI detection rule
        $DetectionRule = New-IntuneWin32AppDetectionRuleMSI -ProductCode $ProductCode
    }
    catch
    {
        Write-Error "Read ProductCode failed: $_"
    }
}
else
{
    # Create PowerShell script detection rule for EXE installer.
    $DetectionScriptFile = "D:\PSADTtest\DetectionRule.ps1"
    $DetectionRule1 = New-IntuneWin32AppDetectionRuleScript -ScriptFile $DetectionScriptFile -EnforceSignatureCheck $false -RunAs32Bit $false

    $DetectionRule = New-IntuneWin32AppDetectionRuleRegistry -StringComparison -KeyPath "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\VLC media player" -ValueName "DisplayVersion" -StringComparisonOperator "equal" -StringComparisonValue "3.0.23"

}

# Create requirement rule for Intel/AMD platforms and Windows 10 20H2
$RequirementRule = New-IntuneWin32AppRequirementRule -Architecture "x64x86" -MinimumSupportedWindowsRelease "W10_1607"

# Create custom return code
$ReturnCode = New-IntuneWin32AppReturnCode -ReturnCode 1337 -Type "retry"

# Add new EXE Win32 app
$InstallCommandLine = "Invoke-AppDeployToolkit.exe -DeploymentType Install"
$UninstallCommandLine = "Invoke-AppDeployToolkit.exe -DeploymentType Uninstall"
Add-IntuneWin32App -FilePath $NewIntuneWinFile -DisplayName $DisplayName -Description "saaa" -Publisher "Autotest" `
    -InstallExperience "system" -RestartBehavior "suppress" -DetectionRule $DetectionRule -RequirementRule $RequirementRule -ReturnCode $ReturnCode `
    -InstallCommandLine $InstallCommandLine -UninstallCommandLine $UninstallCommandLine -Verbose

Write-Host "Win32 app added successfully" -ForegroundColor Green

# Get a specific Win32 app by it's display name
$Win32App = Get-IntuneWin32App -DisplayName $DisplayName -Verbose

# Add an include assignment for a specific Entra ID group
# required, available
$GroupID = "70f69bb0-c68f-458b-a71a-fab85bd4ac98"
Add-IntuneWin32AppAssignmentGroup -Include -ID $Win32App.id -GroupID $GroupID -Intent "required" -Notification "showAll" -Verbose

# Add-IntuneWin32AppAssignmentAllUsers -ID $Win32App.id -Intent "available" -Notification "showAll" -Verbose
