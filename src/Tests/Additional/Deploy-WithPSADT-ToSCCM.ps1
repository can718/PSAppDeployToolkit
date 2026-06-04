#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Package an MSI into local PSADT V3/V4 templates and import into SCCM.

.DESCRIPTION
    Prerequisites - PSADT templates must already exist locally at:
        C:\PSADT\PSADT_Template_v3\
        C:\PSADT\PSADT_Template_v4\

    Execution steps:
    1. Copy local templates -> create V3/V4 package directories
    2. Copy the MSI into each package's Files\ directory
    3. V3: Generate Deploy-Application.ps1 (standard v3 format)
    4. V4: Modify Invoke-AppDeployToolkit.ps1 (inject app info + install commands)
    5. Create SMB share for SCCM content source
    6. Create two SCCM applications with script deployment types

.NOTES
    SCCM: Site SQT | Server vm30028301.vm30028301dom.net
#>

# Write-Host is intentional here: this is a deployment diagnostic script where
# color-coded console output is required and Write-Output/Write-Verbose are insufficient.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[CmdletBinding()]
param(
    # Target deployment collection. Defaults to 'All Systems'. If overridden, the script validates the collection exists first.
    [Parameter(Mandatory = $false)]
    [string]$CollectionName = 'All Systems',

    # Path to PSADT v3 template directory. Defaults to C:\PSADT\PSADT_Template_v3 if not specified.
    # In CI, pass the build output path from steps.exports.outputs.Template_v3.
    [Parameter(Mandatory = $false)]
    [string]$TemplateV3Dir = '',

    # Path to PSADT v4 template directory. Defaults to C:\PSADT\PSADT_Template_v4 if not specified.
    # In CI, pass the build output path from steps.exports.outputs.Template_v4.
    [Parameter(Mandatory = $false)]
    [string]$TemplateV4Dir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#================================================================
#  Configuration -- edit this section for each new application
#================================================================

$MSIFileName = 'PatchMyPC-Publishing-Service-2.1.110.4 (2).msi'
$AppVendor = 'PatchMyPC'
$AppName = 'PatchMyPC Publishing Service'
$AppVersion = '2.1.110.4'

# SCCM site code and server - auto-detect from registry, fallback to hardcoded defaults
$SiteCode = ''
$SiteServer = ''
$SiteCode = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Operations Management" -Name "Site Code" -ErrorAction SilentlyContinue)."Site Code"
$SiteServer = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\SMS\Setup" -Name "Provider Location" -ErrorAction SilentlyContinue)."Provider Location"
if (-not $SiteCode) { $SiteCode = 'SQT' }
if (-not $SiteServer) { $SiteServer = 'vm30028301.vm30028301dom.net' }
Write-Host "Using SCCM Site: $SiteCode | Server: $SiteServer" -ForegroundColor Cyan
# Local directories
$WorkDir = 'C:\PSADT'
$MSISourcePath = Join-Path $WorkDir $MSIFileName
# Template directories: use parameters if provided, otherwise fall back to local defaults
if (-not $TemplateV3Dir) { $TemplateV3Dir = Join-Path $WorkDir 'PSADT_Template_v3' }
if (-not $TemplateV4Dir) { $TemplateV4Dir = Join-Path $WorkDir 'PSADT_Template_v4' }

# Package output directories (rebuilt on each run)
$SafeName = ($AppName -replace '[^\w]', '_')
$V3PackageDir = Join-Path $WorkDir "${SafeName}_v3"
$V4PackageDir = Join-Path $WorkDir "${SafeName}_v4"

# Deployment target collection (overridable via parameter)
$TargetCollection = $CollectionName

# SCCM content share
$ContentShareName = 'PSADT_Content$'
$ContentUNCRoot = "\\$env:COMPUTERNAME\$ContentShareName"
$V3ContentUNC = "$ContentUNCRoot\${SafeName}_v3"
$V4ContentUNC = "$ContentUNCRoot\${SafeName}_v4"

#================================================================
#  Helper functions
#================================================================

function Step
{
    param([string]$t)
    Write-Host "`n$t" -ForegroundColor Cyan
}
function OK
{
    param([string]$m)
    Write-Host "  [+] $m" -ForegroundColor Green
}
function WARN
{
    param([string]$m)
    Write-Host "  [!] $m" -ForegroundColor Yellow
}

function Get-MSIProductCode ([string]$Path)
{
    try
    {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
        $vw = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='ProductCode'"))
        $vw.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $vw, $null)
        $rec = $vw.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $vw, $null)
        $pc = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
        [Runtime.InteropServices.Marshal]::ReleaseComObject($wi) | Out-Null
        return $pc
    }
    catch
    {
        return $null
    }
}

#================================================================
#  STEP 1 -- Validate inputs
#================================================================
Step '[1/6] Validating source file and local templates...'

if (-not (Test-Path $MSISourcePath))
{
    throw "MSI not found: $MSISourcePath"
}
if (-not (Test-Path $TemplateV3Dir))
{
    throw "V3 template not found: $TemplateV3Dir"
}
if (-not (Test-Path $TemplateV4Dir))
{
    throw "V4 template not found: $TemplateV4Dir"
}

$ProductCode = Get-MSIProductCode -Path $MSISourcePath
OK "MSI: $MSIFileName"
if ($ProductCode)
{
    OK "ProductCode: $ProductCode"
}
else
{
    WARN "Could not read ProductCode - will use registry DisplayName for detection"
}

#================================================================
#  STEP 2 -- Build V3 package
#================================================================
Step '[2/6] Building V3 package directory...'

if (Test-Path $V3PackageDir)
{
    Remove-Item $V3PackageDir -Recurse -Force
}
Copy-Item -Path $TemplateV3Dir -Destination $V3PackageDir -Recurse
OK "Template copied -> $V3PackageDir"

$V3Files = Join-Path $V3PackageDir 'Files'
New-Item -ItemType Directory -Path $V3Files -Force | Out-Null
Copy-Item -Path $MSISourcePath -Destination $V3Files -Force
OK "MSI -> $V3Files"

# Generate Deploy-Application.ps1 (must be created manually - not included in PSADT 4.x v3 template)
$V3Script = Join-Path $V3PackageDir 'Deploy-Application.ps1'

$v3UninstallBlock = if ($ProductCode)
{
    "        Execute-MSI -Action 'Uninstall' -Path '$ProductCode'"
}
else
{
    "        Execute-MSI -Action  'Uninstall' -Path `"`$dirFiles\$MSIFileName`""
}

Set-Content -Path $V3Script -Encoding UTF8 -Value @"
<#
.SYNOPSIS
    $AppName $AppVersion - PSADT v3 Deployment Script
    Auto-generated on $(Get-Date -Format 'yyyy-MM-dd')
#>
[CmdletBinding()]
Param (
    [ValidateSet('Install','Uninstall','Repair')]
    [string]`$DeploymentType = 'Install',
    [ValidateSet('Interactive','Silent','NonInteractive')]
    [string]`$DeployMode = 'Interactive',
    [switch]`$AllowRebootPassThru = `$false,
    [switch]`$TerminalServerMode = `$false,
    [switch]`$DisableLogging = `$false
)

Try {
    Try { Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop' } Catch {}

    ##*=============================================
    ##* VARIABLE DECLARATION
    ##*=============================================
    [string]`$appVendor        = '$AppVendor'
    [string]`$appName          = '$AppName'
    [string]`$appVersion       = '$AppVersion'
    [string]`$appArch          = ''
    [string]`$appLang          = 'EN'
    [string]`$appRevision      = '01'
    [string]`$appScriptVersion = '1.0.0'
    [string]`$appScriptDate    = '$(Get-Date -Format "MM/dd/yyyy")'
    [string]`$appScriptAuthor  = 'Auto-generated'

    ## Do not modify below
    [int32]`$mainExitCode = 0
    If (Test-Path -LiteralPath 'variable:HostInvocation') { `$InvocationInfo = `$HostInvocation } Else { `$InvocationInfo = `$MyInvocation }
    [string]`$scriptDirectory = Split-Path -Path `$InvocationInfo.MyCommand.Definition -Parent

    Try {
        [string]`$moduleMain = "`$scriptDirectory\AppDeployToolkit\AppDeployToolkitMain.ps1"
        If (-not (Test-Path -LiteralPath `$moduleMain -PathType 'Leaf')) { Throw "Module not found: [`$moduleMain]" }
        If (`$DisableLogging) { . `$moduleMain -DisableLogging } Else { . `$moduleMain }
    } Catch {
        If (`$mainExitCode -eq 0) { [int32]`$mainExitCode = 60008 }
        Write-Error -Message "Module failed to load: ``n`$(`$_.Exception.Message)" -ErrorAction 'Continue'
        If (Test-Path -LiteralPath 'variable:HostInvocation') { `$script:ExitCode = `$mainExitCode; Exit } Else { Exit `$mainExitCode }
    }
    ##*=============================================

    If (`$deploymentType -ine 'Uninstall' -and `$deploymentType -ine 'Repair') {

        ##*=============================================
        ##* PRE-INSTALLATION
        ##*=============================================
        [string]`$installPhase = 'Pre-Installation'

        Show-InstallationWelcome -AllowDefer -DeferTimes 3 -CheckDiskSpace -PersistPrompt
        Show-InstallationProgress

        ##*=============================================
        ##* INSTALLATION
        ##*=============================================
        [string]`$installPhase = 'Installation'

        Execute-MSI -Action 'Install' -Path "`$dirFiles\$MSIFileName" -Parameters '/QN REBOOT=ReallySuppress'

        ##*=============================================
        ##* POST-INSTALLATION
        ##*=============================================
        [string]`$installPhase = 'Post-Installation'

    } ElseIf (`$deploymentType -ieq 'Uninstall') {

        ##*=============================================
        ##* PRE-UNINSTALLATION
        ##*=============================================
        [string]`$installPhase = 'Pre-Uninstallation'

        Show-InstallationWelcome -CloseAppsCountdown 60
        Show-InstallationProgress

        ##*=============================================
        ##* UNINSTALLATION
        ##*=============================================
        [string]`$installPhase = 'Uninstallation'

$v3UninstallBlock

        ##*=============================================
        ##* POST-UNINSTALLATION
        ##*=============================================
        [string]`$installPhase = 'Post-Uninstallation'

    } ElseIf (`$deploymentType -ieq 'Repair') {

        ##*=============================================
        ##* PRE-REPAIR
        ##*=============================================
        [string]`$installPhase = 'Pre-Repair'

        Show-InstallationWelcome
        Show-InstallationProgress

        ##*=============================================
        ##* REPAIR
        ##*=============================================
        [string]`$installPhase = 'Repair'

        Execute-MSI -Action 'Repair' -Path "`$dirFiles\$MSIFileName" -Parameters '/QN REBOOT=ReallySuppress'

        ##*=============================================
        ##* POST-REPAIR
        ##*=============================================
        [string]`$installPhase = 'Post-Repair'
    }

    Exit-Script -ExitCode `$mainExitCode
} Catch {
    [int32]`$mainExitCode = 60001
    Write-Log -Message "`$(Resolve-Error)" -Severity 3 -Source 'Deploy-Application'
    Exit-Script -ExitCode `$mainExitCode
}
"@

OK "Deploy-Application.ps1 created: $V3Script"

#================================================================
#  STEP 3 -- Build V4 package
#================================================================
Step '[3/6] Building V4 package directory...'

if (Test-Path $V4PackageDir)
{
    Remove-Item $V4PackageDir -Recurse -Force
}
Copy-Item -Path $TemplateV4Dir -Destination $V4PackageDir -Recurse
OK "Template copied -> $V4PackageDir"

$V4Files = Join-Path $V4PackageDir 'Files'
New-Item -ItemType Directory -Path $V4Files -Force | Out-Null
Copy-Item -Path $MSISourcePath -Destination $V4Files -Force
OK "MSI -> $V4Files"

# Modify Invoke-AppDeployToolkit.ps1 with app-specific values
$V4Script = Join-Path $V4PackageDir 'Invoke-AppDeployToolkit.ps1'
if (-not (Test-Path $V4Script))
{
    throw "Invoke-AppDeployToolkit.ps1 not found: $V4Script"
}

$v4 = Get-Content $V4Script -Raw

# Inject app info into the $adtSession hashtable (replace empty string fields)
$v4 = $v4 -replace "(?m)^(\s*AppVendor\s*=\s*)'[^']*'", "`$1'$AppVendor'"
$v4 = $v4 -replace "(?m)^(\s*AppName\s*=\s*)'[^']*'", "`$1'$AppName'"
$v4 = $v4 -replace "(?m)^(\s*AppVersion\s*=\s*)'[^']*'", "`$1'$AppVersion'"

# Inject install/uninstall commands
$v4InstallCmd = "    Start-ADTMsiProcess -Action 'Install' -FilePath '$MSIFileName' -AdditionalArgumentList '/QN REBOOT=ReallySuppress'"

$v4UninstallCmd = if ($ProductCode)
{
    "    Start-ADTMsiProcess -Action 'Uninstall' -FilePath '$ProductCode'"
}
else
{
    "    Start-ADTMsiProcess -Action 'Uninstall' -FilePath '$MSIFileName'"
}

# Insert commands after the placeholder comments in Install and Uninstall sections
$v4 = $v4.Replace(
    '    ## <Perform Installation tasks here>',
    "    ## <Perform Installation tasks here>`n`n$v4InstallCmd"
)
$v4 = $v4.Replace(
    '    ## <Perform Uninstallation tasks here>',
    "    ## <Perform Uninstallation tasks here>`n`n$v4UninstallCmd"
)

Set-Content -Path $V4Script -Value $v4 -Encoding UTF8 -NoNewline
OK "Invoke-AppDeployToolkit.ps1 modified: $V4Script"

# Verify the modifications were applied
$checkV4 = Get-Content $V4Script -Raw
if ($checkV4 -match [regex]::Escape("'$AppName'") -and $checkV4 -match 'Start-ADTMsiProcess')
{
    OK 'V4 script modification verified'
}
else
{
    WARN "V4 script modification may be incomplete - please review $V4Script manually"
}

#================================================================
#  STEP 4 -- Verify package contents
#================================================================
Step '[4/6] Verifying package contents...'

OK 'V3 package root files:'
Get-ChildItem $V3PackageDir -File | ForEach-Object { Write-Host "        $($_.Name)" }
OK 'V4 package root files:'
Get-ChildItem $V4PackageDir -File | ForEach-Object { Write-Host "        $($_.Name)" }
OK 'Files\ contents:'
Get-ChildItem $V3Files | ForEach-Object { Write-Host "        V3/Files/$($_.Name)" }
Get-ChildItem $V4Files | ForEach-Object { Write-Host "        V4/Files/$($_.Name)" }

#================================================================
#  STEP 5 -- Ensure SMB share exists
#================================================================
Step '[5/6] Ensuring SMB content share exists...'

if (-not (Get-SmbShare -Name $ContentShareName -ErrorAction SilentlyContinue))
{
    New-SmbShare -Name $ContentShareName -Path $WorkDir -FullAccess 'Everyone' `
        -Description 'PSADT SCCM Content Source' | Out-Null
    OK "Share created: \\$env:COMPUTERNAME\$ContentShareName -> $WorkDir"
}
else
{
    OK "Share already exists: \\$env:COMPUTERNAME\$ContentShareName"
}

#================================================================
#  STEP 6 -- Import into SCCM
#================================================================
Step '[6/6] Importing into SCCM (Site: SQT)...'

# Load the ConfigurationManager module
if (-not (Get-Module ConfigurationManager -ErrorAction SilentlyContinue))
{
    $possiblePaths = @(
        'C:\Program Files (x86)\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1',
        'C:\Program Files\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1'
    )
    if ($env:SMS_ADMIN_UI_PATH)
    {
        $possiblePaths += Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
    }
    $cmModule = $possiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $cmModule)
    {
        throw 'ConfigurationManager.psd1 not found - ensure the SCCM Admin Console is installed'
    }
    Import-Module $cmModule -ErrorAction Stop
    OK "Module loaded: $cmModule"
}

$origLoc = Get-Location
if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue))
{
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer | Out-Null
}
Set-Location "${SiteCode}:\"

try
{
    # Detection script (registry check, supports both x86 and x64 uninstall keys)
    $detectScript = if ($ProductCode)
    {
        @"
`$paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode'
)
if (`$paths | Where-Object { Test-Path `$_ }) { Write-Host 'Installed' }
"@
    }
    else
    {
        @"
`$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
`$app = foreach (`$root in `$uninstallRoots)
{
    if (Test-Path `$root)
    {
        Get-ChildItem -Path `$root |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { `$_.DisplayName -like '*$AppName*' -and `$_.DisplayVersion -eq '$AppVersion' }
    }
}
if (`$app) { Write-Host 'Installed' }
"@
    }

    # Launch commands (prefer .exe launcher if present, fall back to powershell.exe)
    $V3InstallCmd = if (Test-Path (Join-Path $V3PackageDir 'Deploy-Application.exe'))
    {
        'Deploy-Application.exe Install'
    }
    else
    {
        'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Deploy-Application.ps1" -DeploymentType Install'
    }
    $V3UninstallCmd = if (Test-Path (Join-Path $V3PackageDir 'Deploy-Application.exe'))
    {
        'Deploy-Application.exe Uninstall'
    }
    else
    {
        'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Deploy-Application.ps1" -DeploymentType Uninstall'
    }
    $V4InstallCmd = if (Test-Path (Join-Path $V4PackageDir 'Invoke-AppDeployToolkit.exe'))
    {
        'Invoke-AppDeployToolkit.exe Install'
    }
    else
    {
        'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Install'
    }
    $V4UninstallCmd = if (Test-Path (Join-Path $V4PackageDir 'Invoke-AppDeployToolkit.exe'))
    {
        'Invoke-AppDeployToolkit.exe Uninstall'
    }
    else
    {
        'powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "Invoke-AppDeployToolkit.ps1" -DeploymentType Uninstall'
    }

    # -- V3 Application --
    $V3AppName = "$AppName (PSADT v3)"
    if (Get-CMApplication -Name $V3AppName -ErrorAction SilentlyContinue)
    {
        WARN "'$V3AppName' already exists - removing deployments then application..."
        $v3Deployments = Get-CMApplicationDeployment -Name $V3AppName -ErrorAction SilentlyContinue
        foreach ($dep in $v3Deployments)
        {
            Remove-CMApplicationDeployment -Name $V3AppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
        }
        Remove-CMApplication -Name $V3AppName -Force
        Start-Sleep -Seconds 2
    }
    Write-Host "  Creating: $V3AppName"
    New-CMApplication `
        -Name            $V3AppName `
        -Publisher       $AppVendor `
        -SoftwareVersion $AppVersion `
        -LocalizedName   $V3AppName `
        -Description     "PSADT v3 compatibility template - $AppName $AppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')" | Out-Null

    $V3DTName = "$AppName $AppVersion (v3)"
    Add-CMScriptDeploymentType `
        -ApplicationName          $V3AppName `
        -DeploymentTypeName       $V3DTName `
        -ContentLocation          $V3ContentUNC `
        -InstallCommand           $V3InstallCmd `
        -UninstallCommand         $V3UninstallCmd `
        -ScriptLanguage           PowerShell `
        -ScriptText               $detectScript `
        -InstallationBehaviorType InstallForSystem `
        -LogonRequirementType     WhetherOrNotUserLoggedOn `
        -RebootBehavior           BasedOnExitCode `
        -SlowNetworkDeploymentMode Download `
        -MaximumRuntimeMins       30 `
        -EstimatedRuntimeMins     5 | Out-Null

    # Add PSADT return codes: 3010 = restart required (SoftReboot), 1641 = restart initiated (HardReboot)
    try
    {
        $v3dt = Get-CMDeploymentType -ApplicationName $V3AppName -DeploymentTypeName $V3DTName
        Add-CMDeploymentTypeReturnCode -InputObject $v3dt -ReturnCode 3010 -CodeType SoftReboot -Name 'Reboot Required'    | Out-Null
        Add-CMDeploymentTypeReturnCode -InputObject $v3dt -ReturnCode 1641 -CodeType HardReboot -Name 'Reboot Initiated'  | Out-Null
        OK 'V3 return codes configured (3010/1641)'
    }
    catch
    {
        WARN "V3 return code configuration skipped: $($_.Exception.Message)"
    }
    OK "V3 application created: $V3AppName"

    # -- V4 Application --
    $V4AppName = "$AppName (PSADT v4)"
    if (Get-CMApplication -Name $V4AppName -ErrorAction SilentlyContinue)
    {
        WARN "'$V4AppName' already exists - removing deployments then application..."
        $v4Deployments = Get-CMApplicationDeployment -Name $V4AppName -ErrorAction SilentlyContinue
        foreach ($dep in $v4Deployments)
        {
            Remove-CMApplicationDeployment -Name $V4AppName -CollectionName $dep.CollectionName -Force -ErrorAction SilentlyContinue
        }
        Remove-CMApplication -Name $V4AppName -Force
        Start-Sleep -Seconds 2
    }
    Write-Host "  Creating: $V4AppName"
    New-CMApplication `
        -Name            $V4AppName `
        -Publisher       $AppVendor `
        -SoftwareVersion $AppVersion `
        -LocalizedName   $V4AppName `
        -Description     "PSADT v4 native template - $AppName $AppVersion - auto-created $(Get-Date -Format 'yyyy-MM-dd')" | Out-Null

    $V4DTName = "$AppName $AppVersion (v4)"
    Add-CMScriptDeploymentType `
        -ApplicationName          $V4AppName `
        -DeploymentTypeName       $V4DTName `
        -ContentLocation          $V4ContentUNC `
        -InstallCommand           $V4InstallCmd `
        -UninstallCommand         $V4UninstallCmd `
        -ScriptLanguage           PowerShell `
        -ScriptText               $detectScript `
        -InstallationBehaviorType InstallForSystem `
        -LogonRequirementType     WhetherOrNotUserLoggedOn `
        -RebootBehavior           BasedOnExitCode `
        -SlowNetworkDeploymentMode Download `
        -MaximumRuntimeMins       30 `
        -EstimatedRuntimeMins     5 | Out-Null

    # Add PSADT return codes: 3010 = restart required (SoftReboot), 1641 = restart initiated (HardReboot)
    try
    {
        $v4dt = Get-CMDeploymentType -ApplicationName $V4AppName -DeploymentTypeName $V4DTName
        Add-CMDeploymentTypeReturnCode -InputObject $v4dt -ReturnCode 3010 -CodeType SoftReboot -Name 'Reboot Required'    | Out-Null
        Add-CMDeploymentTypeReturnCode -InputObject $v4dt -ReturnCode 1641 -CodeType HardReboot -Name 'Reboot Initiated'  | Out-Null
        OK 'V4 return codes configured (3010/1641)'
    }
    catch
    {
        WARN "V4 return code configuration skipped: $($_.Exception.Message)"
    }
    OK "V4 application created: $V4AppName"

    #================================================================
    #  Distribute content to distribution points
    #================================================================
    Write-Host ''
    Step 'Distributing content to distribution points...'

    # Prefer DP groups; fall back to distributing to individual DPs
    $dpGroups = Get-CMDistributionPointGroup -ErrorAction SilentlyContinue
    $dpList = Get-CMDistributionPoint -ErrorAction SilentlyContinue

    if (-not $dpGroups -and -not $dpList)
    {
        throw 'No distribution points or distribution point groups found - configure a DP in SCCM first'
    }

    foreach ($appDistName in @($V3AppName, $V4AppName))
    {
        if ($dpGroups)
        {
            foreach ($grp in $dpGroups)
            {
                Start-CMContentDistribution -ApplicationName $appDistName `
                    -DistributionPointGroupName $grp.Name -ErrorAction SilentlyContinue | Out-Null
            }
            OK "Content distribution triggered (DP Group): $appDistName -> $($dpGroups.Name -join ', ')"
        }
        else
        {
            foreach ($dp in $dpList)
            {
                $dpFQDN = $dp.NetworkOSPath.TrimStart('\')
                Start-CMContentDistribution -ApplicationName $appDistName `
                    -DistributionPointName $dpFQDN -ErrorAction SilentlyContinue | Out-Null
            }
            OK "Content distribution triggered (DP): $appDistName -> $($dpList.Count) distribution point(s)"
        }
    }

    #================================================================
    #  Deploy to collection
    #================================================================
    Write-Host ''
    Step "Deploying applications to collection: $TargetCollection"

    # Validate the collection exists if not using the default
    if ($TargetCollection -ne 'All Systems')
    {
        $col = Get-CMDeviceCollection -Name $TargetCollection -ErrorAction SilentlyContinue
        if (-not $col)
        {
            throw "Collection not found: '$TargetCollection' - create it in SCCM first"
        }
        OK "Collection validated: $TargetCollection ($($col.MemberCount) device(s))"
    }

    foreach ($appDeployName in @($V3AppName, $V4AppName))
    {
        # Remove existing deployment to the same collection before recreating
        $existDeploy = Get-CMApplicationDeployment -Name $appDeployName -CollectionName $TargetCollection -ErrorAction SilentlyContinue
        if ($existDeploy)
        {
            Remove-CMApplicationDeployment -Name $appDeployName -CollectionName $TargetCollection -Force
            WARN "Removed existing deployment: $appDeployName -> $TargetCollection"
        }

        New-CMApplicationDeployment `
            -Name                       $appDeployName `
            -CollectionName             $TargetCollection `
            -DeployAction               Install `
            -DeployPurpose              Required `
            -UserNotification           DisplaySoftwareCenterOnly `
            -TimeBaseOn                 LocalTime `
            -OverrideServiceWindow      $false `
            -RebootOutsideServiceWindow $false | Out-Null
        OK "Deployed (Required): $appDeployName -> $TargetCollection"
    }

    # -- Summary --
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Green
    Write-Host ' All done!' -ForegroundColor Green
    Write-Host ('=' * 62) -ForegroundColor Green
    Write-Host ''
    Write-Host '  SCCM Applications:'
    Write-Host "    $V3AppName"
    Write-Host "    $V4AppName"
    Write-Host ''
    Write-Host '  Content source UNC:'
    Write-Host "    $V3ContentUNC"
    Write-Host "    $V4ContentUNC"
    Write-Host ''
    Write-Host '  Local package directories:'
    Write-Host "    $V3PackageDir"
    Write-Host "    $V4PackageDir"
    if ($ProductCode)
    {
        Write-Host ''
        Write-Host "  MSI ProductCode: $ProductCode"
    }
    Write-Host ''
    Write-Host "  Deployment target: $TargetCollection (Required)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Next steps:' -ForegroundColor Yellow
    Write-Host '    1. Content distribution has been triggered automatically'
    Write-Host '    2. Deployment is created - clients will install on next policy refresh'
    Write-Host ''

}
finally
{
    Set-Location $origLoc
}
