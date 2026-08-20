[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    'NewADTTemplateParameters',
    Justification = 'This hashtable is consumed by external test harness code after the script is loaded.'
)]
$NotepadPlusPlusUseForceCloseProcessesCountdown = $false
. (Join-Path $PSScriptRoot 'New-ADTTemplate.params.shared.ps1')
