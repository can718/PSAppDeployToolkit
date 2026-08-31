#pragma warning disable PSPlaceOpenBrace

function Save-PSADTTestAppInstaller
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [string]$LogPrefix = 'TestApp'
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container))
    {
        New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
        Write-Information "::info::[$LogPrefix] Created installer cache directory '$DestinationDirectory'." -InformationAction Continue
    }

    $destinationPath = Join-Path $DestinationDirectory $FileName
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf))
    {
        Write-Information "::info::[$LogPrefix] Downloading installer '$FileName' from '$Uri'..." -InformationAction Continue
        Invoke-WebRequest -Uri $Uri -OutFile $destinationPath -UseBasicParsing -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf))
        {
            throw "[$LogPrefix] Installer download completed but file was not found at '$destinationPath'."
        }
    }
    else
    {
        Write-Information "::info::[$LogPrefix] Reusing cached installer '$destinationPath'." -InformationAction Continue
    }

    return $destinationPath
}

function Start-PSADTTestAppProcess
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [string]$LogPrefix = 'TestApp',

        [string]$Description = $ProcessName
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf))
    {
        throw "[$LogPrefix] Launch path not found: $FilePath"
    }

    Write-Information "::info::[$LogPrefix] Launching $Description process from '$FilePath'." -InformationAction Continue
    Start-Process -FilePath $FilePath
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue))
    {
        throw "[$LogPrefix] $Description process was not running before deployment."
    }
}

function Invoke-PSADTTestMsiProcessWithRetry
{
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArgumentList,

        [string]$LogPrefix = 'TestApp',

        [string]$Description = 'MSI operation',

        [int[]]$SuccessExitCodes = @(0, 3010),

        [int[]]$RetryExitCodes = @(1618),

        [int]$MaxAttempts = 5,

        [int]$RetryDelaySeconds = 30
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++)
    {
        Write-Information "::info::[$LogPrefix] $Description attempt $attempt/$MaxAttempts." -InformationAction Continue
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $ArgumentList -Wait -NoNewWindow -PassThru
        $exitCode = $process.ExitCode
        if ($SuccessExitCodes -contains $exitCode)
        {
            Write-Information "::info::[$LogPrefix] $Description completed with exit code $exitCode." -InformationAction Continue
            return $true
        }

        if ($RetryExitCodes -contains $exitCode -and $attempt -lt $MaxAttempts)
        {
            Write-Warning "[$LogPrefix] $Description returned exit code $exitCode. Another installation may be in progress; retrying in $RetryDelaySeconds seconds."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
        else
        {
            Write-Warning "[$LogPrefix] $Description failed with exit code $exitCode."
            return $false
        }
    }

    return $false
}

function Get-NotepadPlusPlusTestEnvironmentDefaults
{
    $legacyVersion = '8.9.7'
    $targetVersion = '8.9.8'
    $legacyInstallerName = "npp.$legacyVersion.Installer.exe"
    $targetInstallerName = "npp.$targetVersion.Installer.exe"
    $intuneLegacyInstallerDir = "C:\Tools\Intune\Notepad$legacyVersion"
    $intuneTargetInstallerDir = "C:\Tools\Intune\Notepad$targetVersion"

    return @{
        LegacyVersion                       = $legacyVersion
        TargetVersion                       = $targetVersion
        LegacyInstallerName                 = $legacyInstallerName
        TargetInstallerName                 = $targetInstallerName
        LegacyInstallerUri                  = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v$legacyVersion/$legacyInstallerName"
        TargetInstallerUri                  = "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v$targetVersion/$targetInstallerName"
        IntuneLegacyInstallerDir            = $intuneLegacyInstallerDir
        IntuneTargetInstallerDir            = $intuneTargetInstallerDir
        IntuneTemplateExpectedInstallerPath = Join-Path $intuneTargetInstallerDir $targetInstallerName
        SccmLegacyInstallerDir              = "C:\Tools\SCCM\NotepadPlusPlus\$legacyVersion"
        SccmTargetInstallerDir              = "C:\Tools\SCCM\NotepadPlusPlus\$targetVersion"
        LegacyVersionPattern                = "^$([System.Text.RegularExpressions.Regex]::Escape($legacyVersion))(\.|$)"
    }
}

function Initialize-NotepadPlusPlusTemplateInstaller
{
    param (
        [string]$TargetInstallerDir,
        [string]$TargetInstallerName,
        [string]$TargetInstallerUri,
        [string]$TemplateExpectedInstallerPath,
        [string]$LogPrefix = 'Notepad++'
    )

    $notepadPlusPlusTestConfig = Get-NotepadPlusPlusTestEnvironmentDefaults
    if ([System.String]::IsNullOrWhiteSpace($TargetInstallerDir)) { $TargetInstallerDir = $notepadPlusPlusTestConfig.IntuneTargetInstallerDir }
    if ([System.String]::IsNullOrWhiteSpace($TargetInstallerName)) { $TargetInstallerName = $notepadPlusPlusTestConfig.TargetInstallerName }
    if ([System.String]::IsNullOrWhiteSpace($TargetInstallerUri)) { $TargetInstallerUri = $notepadPlusPlusTestConfig.TargetInstallerUri }
    if ($null -eq $TemplateExpectedInstallerPath) { $TemplateExpectedInstallerPath = $notepadPlusPlusTestConfig.IntuneTemplateExpectedInstallerPath }

    $targetInstallerPath = Save-PSADTTestAppInstaller `
        -DestinationDirectory $TargetInstallerDir `
        -FileName $TargetInstallerName `
        -Uri $TargetInstallerUri `
        -LogPrefix $LogPrefix

    if (-not [System.String]::IsNullOrWhiteSpace($TemplateExpectedInstallerPath))
    {
        if (-not (Test-Path -LiteralPath $targetInstallerPath -PathType Leaf))
        {
            throw "[$LogPrefix] Target installer source was not found after download: '$targetInstallerPath'."
        }

        if ([System.String]::Equals([System.IO.Path]::GetFullPath($targetInstallerPath), [System.IO.Path]::GetFullPath($TemplateExpectedInstallerPath), [System.StringComparison]::OrdinalIgnoreCase))
        {
            Write-Information "::info::[$LogPrefix] Template installer is available at '$TemplateExpectedInstallerPath'." -InformationAction Continue
            return $targetInstallerPath
        }

        New-Item -Path (Split-Path -Path $TemplateExpectedInstallerPath -Parent) -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $targetInstallerPath -Destination $TemplateExpectedInstallerPath -Force -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $TemplateExpectedInstallerPath -PathType Leaf))
        {
            throw "[$LogPrefix] Target installer copy completed but template path was not found: '$TemplateExpectedInstallerPath'."
        }

        Write-Information "::info::[$LogPrefix] Copied installer '$targetInstallerPath' to template path '$TemplateExpectedInstallerPath'." -InformationAction Continue
    }

    return $targetInstallerPath
}

function Initialize-NotepadPlusPlusLegacyTestEnvironment
{
    param (
        [string]$LegacyInstallerDir,
        [string]$LegacyInstallerName,
        [string]$LegacyInstallerUri,
        [string]$TargetInstallerDir,
        [string]$TargetInstallerName,
        [string]$TargetInstallerUri,
        [string]$TemplateExpectedInstallerPath,
        [string]$LegacyVersionPattern,
        [string]$LogPrefix = 'Notepad++',
        [switch]$LaunchLegacyProcess
    )

    $notepadPlusPlusTestConfig = Get-NotepadPlusPlusTestEnvironmentDefaults
    if ([System.String]::IsNullOrWhiteSpace($LegacyInstallerDir)) { $LegacyInstallerDir = $notepadPlusPlusTestConfig.IntuneLegacyInstallerDir }
    if ([System.String]::IsNullOrWhiteSpace($LegacyInstallerName)) { $LegacyInstallerName = $notepadPlusPlusTestConfig.LegacyInstallerName }
    if ([System.String]::IsNullOrWhiteSpace($LegacyInstallerUri)) { $LegacyInstallerUri = $notepadPlusPlusTestConfig.LegacyInstallerUri }
    if ([System.String]::IsNullOrWhiteSpace($TargetInstallerDir)) { $TargetInstallerDir = $notepadPlusPlusTestConfig.IntuneTargetInstallerDir }
    if ([System.String]::IsNullOrWhiteSpace($TargetInstallerName)) { $TargetInstallerName = $notepadPlusPlusTestConfig.TargetInstallerName }
    if ([System.String]::IsNullOrWhiteSpace($TargetInstallerUri)) { $TargetInstallerUri = $notepadPlusPlusTestConfig.TargetInstallerUri }
    if ($null -eq $TemplateExpectedInstallerPath) { $TemplateExpectedInstallerPath = $notepadPlusPlusTestConfig.IntuneTemplateExpectedInstallerPath }
    if ([System.String]::IsNullOrWhiteSpace($LegacyVersionPattern)) { $LegacyVersionPattern = $notepadPlusPlusTestConfig.LegacyVersionPattern }

    $legacyInstallerPath = Save-PSADTTestAppInstaller `
        -DestinationDirectory $LegacyInstallerDir `
        -FileName $LegacyInstallerName `
        -Uri $LegacyInstallerUri `
        -LogPrefix $LogPrefix

    $legacyExePath = Join-Path ${env:ProgramFiles(x86)} 'Notepad++\notepad++.exe'
    $installedLegacyVersion = $null
    if (Test-Path -LiteralPath $legacyExePath -PathType Leaf)
    {
        $installedLegacyVersion = (Get-Item -LiteralPath $legacyExePath).VersionInfo.FileVersion
    }

    if ($installedLegacyVersion -match $LegacyVersionPattern)
    {
        Write-Information "::info::[$LogPrefix] Legacy version already installed: $installedLegacyVersion" -InformationAction Continue
    }
    else
    {
        Write-Information "::info::[$LogPrefix] Installing legacy Notepad++ prerequisite from '$legacyInstallerPath'." -InformationAction Continue
        Start-Process -FilePath $legacyInstallerPath -ArgumentList '/S' -Wait -NoNewWindow
    }

    if ($LaunchLegacyProcess)
    {
        Start-PSADTTestAppProcess -FilePath $legacyExePath -ProcessName 'notepad++' -Description 'legacy Notepad++' -LogPrefix $LogPrefix
    }

    $targetInstallerPath = Initialize-NotepadPlusPlusTemplateInstaller `
        -TargetInstallerDir $TargetInstallerDir `
        -TargetInstallerName $TargetInstallerName `
        -TargetInstallerUri $TargetInstallerUri `
        -TemplateExpectedInstallerPath $TemplateExpectedInstallerPath `
        -LogPrefix $LogPrefix

    return @{
        LegacyInstallerPath = $legacyInstallerPath
        LegacyExePath       = $legacyExePath
        TargetInstallerPath = $targetInstallerPath
        TargetInstallerDir  = $TargetInstallerDir
    }
}

function Initialize-SevenZipForceCloseTestEnvironment
{
    param (
        [string]$LegacyInstallerDir = 'C:\Tools\Intune\SevenZipForceClose',
        [string]$LegacyInstallerName = '7z2301-x64.msi',
        [string]$LegacyInstallerUri = 'https://www.7-zip.org/a/7z2301-x64.msi',
        [string]$TargetInstallerDir = 'C:\Tools\Intune\SevenZipForceClose',
        [string]$TargetInstallerName = '7z2409-x64.msi',
        [string]$TargetInstallerUri = 'https://www.7-zip.org/a/7z2409-x64.msi',
        [string]$TemplateExpectedInstallerPath = 'C:\Tools\Intune\7z2409-x64.msi',
        [string]$LogPrefix = '7-Zip ForceClose',
        [switch]$LaunchProcess
    )

    $legacyInstallerPath = Save-PSADTTestAppInstaller `
        -DestinationDirectory $LegacyInstallerDir `
        -FileName $LegacyInstallerName `
        -Uri $LegacyInstallerUri `
        -LogPrefix $LogPrefix

    $targetInstallerPath = Save-PSADTTestAppInstaller `
        -DestinationDirectory $TargetInstallerDir `
        -FileName $TargetInstallerName `
        -Uri $TargetInstallerUri `
        -LogPrefix $LogPrefix

    Get-Process -Name '7zFM' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $sevenZipUninstallEntries = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    ) | ForEach-Object {
        Get-ItemProperty -Path $PSItem -ErrorAction SilentlyContinue | Where-Object { $PSItem.DisplayName -like '7-Zip*' }
    }
    foreach ($entry in $sevenZipUninstallEntries)
    {
        if ($entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$')
        {
            Write-Information "::info::[$LogPrefix] Removing existing 7-Zip installation '$($entry.DisplayName)' before installing legacy prerequisite." -InformationAction Continue
            $uninstalled = Invoke-PSADTTestMsiProcessWithRetry `
                -ArgumentList "/x $($entry.PSChildName) /qn /norestart" `
                -Description "Uninstall existing 7-Zip '$($entry.DisplayName)'" `
                -SuccessExitCodes @(0, 3010, 1605) `
                -LogPrefix $LogPrefix
            if (-not $uninstalled)
            {
                return $null
            }
        }
    }

    Write-Information "::info::[$LogPrefix] Installing legacy 7-Zip prerequisite from '$legacyInstallerPath'." -InformationAction Continue
    $installed = Invoke-PSADTTestMsiProcessWithRetry `
        -ArgumentList "/i `"$legacyInstallerPath`" /qn /norestart" `
        -Description 'Install legacy 7-Zip prerequisite' `
        -LogPrefix $LogPrefix
    if (-not $installed)
    {
        return $null
    }

    if (-not [System.String]::IsNullOrWhiteSpace($TemplateExpectedInstallerPath))
    {
        New-Item -Path (Split-Path -Path $TemplateExpectedInstallerPath -Parent) -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $targetInstallerPath -Destination $TemplateExpectedInstallerPath -Force
    }

    $sevenZipFileManager = Join-Path ${env:ProgramFiles} '7-Zip\7zFM.exe'
    if (-not (Test-Path -LiteralPath $sevenZipFileManager -PathType Leaf))
    {
        Write-Warning "[$LogPrefix] Legacy 7-Zip prerequisite did not create expected launch path: $sevenZipFileManager"
        return $null
    }

    if ($LaunchProcess)
    {
        Start-PSADTTestAppProcess -FilePath $sevenZipFileManager -ProcessName '7zFM' -Description 'legacy 7zFM' -LogPrefix $LogPrefix
    }

    return @{
        LegacyInstallerPath = $legacyInstallerPath
        TargetInstallerPath = $targetInstallerPath
        TargetInstallerDir  = $TargetInstallerDir
        FileManagerPath     = $sevenZipFileManager
    }
}

#pragma warning restore PSPlaceOpenBrace