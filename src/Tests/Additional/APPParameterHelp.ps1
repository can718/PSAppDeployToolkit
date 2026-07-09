function script:Get-PSADTNotepadPlusPlusAppParameters
{
    return @{
        SourceScriptRelativePath = 'Notepad++\Invoke-AppDeployToolkit.ps1'
        PackageDir               = 'C:\PSADT\NotepadPlusPlus'
        AppName                  = 'Notepad++ (PSADT v4 Notepad++)'
        AppVendor                = 'Don HO don.h@free.fr'
        AppVersion               = '6.6.4'
        DeploymentTypeName       = 'Notepad++ 6.6.4 (v4 Notepad++)'
        ContentSubPath           = 'NotepadPlusPlus'
        DetectScript             = @'
$uninstallKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Notepad++'
if (Test-Path $uninstallKey)
{
    $app = Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue
    if ($app.DisplayVersion -like '6.6.4*')
    {
        Write-Host "Installed"
    }
}
'@
        DescriptionTemplate      = 'PSADT v4 Notepad++ template - Notepad++ {0} - auto-created {1}'
        InstallCommand           = 'Invoke-AppDeployToolkit.exe -DeploymentType Install'
        UninstallCommand         = 'Invoke-AppDeployToolkit.exe -DeploymentType Uninstall'
    }
}

function script:Get-PSADTWinSCPAppParameters
{
    return @{
        SourceScriptRelativePath = 'winSCP\Invoke-AppDeployToolkit.ps1'
        PackageDir               = 'C:\PSADT\winSCP'
        AppName                  = 'WinSCP (PSADT v4 winSCP)'
        AppVendor                = 'Martin Prikryl'
        AppVersion               = '6.5.6'
        DeploymentTypeName       = 'WinSCP 6.5.6 (v4 winSCP)'
        ContentSubPath           = 'winSCP'
        DetectScript             = @'
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$app = foreach ($root in $uninstallRoots)
{
    if (Test-Path $root)
    {
        Get-ChildItem -Path $root |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*WinSCP*' -and $_.DisplayVersion -like '6.5.6*' }
    }
}
if ($app) { Write-Host "Installed" }
'@
        DescriptionTemplate      = 'PSADT v4 winSCP template - WinSCP {0} - auto-created {1}'
        InstallCommand           = $null
        UninstallCommand         = $null
    }
}

function script:Get-PSADTVLCAppParameters
{
    return @{
        SourceScriptRelativePath = 'VLC\Invoke-AppDeployToolkit.ps1'
        SourceFolderRelativePath = 'VLC'
        PackageDir               = 'C:\PSADT\VLC'
        AppName                  = 'VLC media player (PSADT v4 VLC)'
        AppVendor                = 'VideoLAN'
        AppVersion               = '3.0.23'
        DeploymentTypeName       = 'VLC 3.0.23 (v4 VLC)'
        ContentSubPath           = 'VLC'
        DetectScript             = @'
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$app = foreach ($root in $uninstallRoots)
{
    if (Test-Path $root)
    {
        Get-ChildItem -Path $root |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*VLC media player*' -and $_.DisplayVersion -like '3.0.23*' }
    }
}
if ($app) { Write-Host "Installed" }
'@
        DescriptionTemplate      = 'PSADT v4 VLC template - VLC media player {0} - auto-created {1}'
        InstallCommand           = $null
        UninstallCommand         = $null
    }
}

function script:Get-PSADTDigiExamAppParameters
{
    return @{
        SourceScriptRelativePath = '..\V3\Digiexam\Deploy-Application.ps1'
        PackageDir               = 'C:\PSADT\DigiExam'
        AppName                  = 'Digiexam (PSADT v3 Digiexam)'
        AppVendor                = 'DigiExam'
        AppVersion               = '26.1.24'
        DeploymentTypeName       = 'Digiexam 26.1.24 (v3 Digiexam)'
        ContentSubPath           = 'DigiExam'
        DetectScript             = @'
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$app = foreach ($root in $uninstallRoots)
{
    if (Test-Path $root)
    {
        Get-ChildItem -Path $root |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*DigiExam*' -and $_.DisplayVersion -like '26.1.24*' }
    }
}
if ($app) { Write-Host "Installed" }
'@
        DescriptionTemplate      = 'PSADT v3 DigiExam template - DigiExam {0} - auto-created {1}'
        InstallCommand           = $null
        UninstallCommand         = $null
    }
}

function script:Get-PSADTEverythingAppParameters
{
    return @{
        SourceScriptRelativePath = '..\V3\Everything\Deploy-Application.ps1'
        PackageDir               = 'C:\PSADT\Everything'
        AppName                  = 'Everything (PSADT v3 Everything)'
        AppVendor                = 'voidtools'
        AppVersion               = '1.4.1.1032'
        DeploymentTypeName       = 'Everything 1.4.1.1032 (v3 Everything)'
        ContentSubPath           = 'Everything'
        DetectScript             = @'
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$app = foreach ($root in $uninstallRoots)
{
    if (Test-Path $root)
    {
        Get-ChildItem -Path $root |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Everything*' -and $_.DisplayVersion -like '1.4.1.1032*' }
    }
}
if ($app) { Write-Host "Installed" }
'@
        DescriptionTemplate      = 'PSADT v3 Everything template - Everything {0} - auto-created {1}'
        InstallCommand           = $null
        UninstallCommand         = $null
    }
}