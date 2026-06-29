@{
    RootModule = 'PSAppDeployToolkit.Recording.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'f7b6c8b6-7ab4-4ef6-9483-1de2f2f2f31b'
    Author = 'PSAppDeployToolkit'
    CompanyName = 'PSAppDeployToolkit'
    Copyright = '(c) PSAppDeployToolkit.'
    Description = 'Recording helper module for Additional Tests in PSADT V4.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'Start-AdditionalTestRecording',
        'Stop-AdditionalTestRecording',
        'Register-AdditionalTestRecordingCallbacks',
        'Import-AdditionalTestRecordingHelper'
    )

    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
