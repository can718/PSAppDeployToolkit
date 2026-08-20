[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    'NewADTTemplateParameters',
    Justification = 'This hashtable is consumed by external test harness code after the script is loaded.'
)]
$NotepadPlusPlusUseForceCloseProcessesCountdown = $true
$NotepadPlusPlusTargetVersion = '6.8.8'
$NotepadPlusPlusInstallerPath = 'C:\Tools\Intune\npp.6.8.8.Installer.exe'
. (Join-Path $PSScriptRoot '..\Notepad++\New-ADTTemplate.params.shared.ps1')