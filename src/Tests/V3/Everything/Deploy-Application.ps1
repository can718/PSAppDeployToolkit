<#
.SYNOPSIS

PSApppDeployToolkit - This script performs the installation or uninstallation of an application(s).

.DESCRIPTION

- The script is provided as a template to perform an install or uninstall of an application(s).
- The script either performs an "Install" deployment type or an "Uninstall" deployment type.
- The install deployment type is broken down into 3 main sections/phases: Pre-Install, Install, and Post-Install.

The script dot-sources the AppDeployToolkitMain.ps1 script which contains the logic and functions required to install or uninstall an application.

PSApppDeployToolkit is licensed under the GNU LGPLv3 License - (C) 2023 PSAppDeployToolkit Team (Sean Lillis, Dan Cunningham and Muhammad Mashwani).

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License as published by the
Free Software Foundation, either version 3 of the License, or any later version. This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
for more details. You should have received a copy of the GNU Lesser General Public License along with this program. if not, see <http://www.gnu.org/licenses/>.

.PARAMETER DeploymentType

The type of deployment to perform. Default is: Install.

.PARAMETER DeployMode

Specifies whether the installation should be run in Interactive, Silent, or NonInteractive mode. Default is: Interactive. Options: Interactive = Shows dialogs, Silent = No dialogs, NonInteractive = Very silent, i.e. no blocking apps. NonInteractive mode is automatically set if it is detected that the process is not user interactive.

.PARAMETER AllowRebootPassThru

Allows the 3010 return code (requires restart) to be passed back to the parent process (e.g. SCCM) if detected from an installation. if 3010 is passed back to SCCM, a reboot prompt will be triggered.

.PARAMETER TerminalServerMode

Changes to "user install mode" and back to "user execute mode" for installing/uninstalling applications for Remote Desktop Session Hosts/Citrix servers.

.PARAMETER DisableLogging

Disables logging to file for the script. Default is: $false.

.EXAMPLE

powershell.exe -Command "& { & '.\Deploy-Application.ps1' -DeployMode 'Silent'; exit $LastExitCode }"

.EXAMPLE

powershell.exe -Command "& { & '.\Deploy-Application.ps1' -AllowRebootPassThru; exit $LastExitCode }"

.EXAMPLE

powershell.exe -Command "& { & '.\Deploy-Application.ps1' -DeploymentType 'Uninstall'; exit $LastExitCode }"

.EXAMPLE

Deploy-Application.exe -DeploymentType "Install" -DeployMode "Silent"

.INPUTS

None

You cannot pipe objects to this script.

.OUTPUTS

None

This script does not generate any output.

.NOTES

Toolkit exit Code Ranges:
- 60000 - 68999: Reserved for built-in exit codes in Deploy-Application.ps1, Deploy-Application.exe, and AppDeployToolkitMain.ps1
- 69000 - 69999: Recommended for user customized exit codes in Deploy-Application.ps1
- 70000 - 79999: Recommended for user customized exit codes in AppDeployToolkitExtensions.ps1

.LINK

https://psappdeploytoolkit.com
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [String]$DeploymentType = 'Install',
    [Parameter(Mandatory = $false)]
    [ValidateSet('Interactive', 'Silent', 'NonInteractive')]
    [String]$DeployMode = 'Interactive',
    [Parameter(Mandatory = $false)]
    [switch]$AllowRebootPassThru = $false,
    [Parameter(Mandatory = $false)]
    [switch]$TerminalServerMode = $false,
    [Parameter(Mandatory = $false)]
    [switch]$DisableLogging = $false
)

try
{
    ## Set the script execution policy for this process
    try
    {
        Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop'
    }
    catch
    {
        Write-Error -Message "Failed to set execution policy for process scope: $($_.Exception.Message)" -ErrorAction 'Continue'
    }

    ##*===============================================
    ##* VARIABLE DECLARATION
    ##*===============================================
    ## Variables: Application
    [String]$appVendor = 'Voidtools'
    [String]$appName = 'Everything'
    [String]$appVersion = '1.4.1.1032'
    [String]$appArch = 'x64'
    [String]$appLang = 'EN'
    [String]$appRevision = '01'
    [String]$appScriptVersion = '1.0.0'
    [String]$appScriptDate = '03/05/2024'
    [String]$appScriptAuthor = 'PsAppDeployToolkit'
    ##*===============================================
    ## Variables: Install Titles (Only set here to override defaults set by the toolkit)
    [String]$installName = ''
    [String]$installTitle = ''

    ##* Do not modify section below
    #region DoNotModify

    ## Variables: exit Code
    [Int32]$mainExitCode = 0

    ## Variables: Script
    [String]$deployAppScriptFriendlyName = 'Deploy Application'
    [Version]$deployAppScriptVersion = [Version]'3.10.1'
    [String]$deployAppScriptDate = '03/05/2024'
    [Hashtable]$deployAppScriptParameters = $PsBoundParameters

    ## Variables: Environment
    if (Test-Path -LiteralPath 'variable:HostInvocation')
    {
        $InvocationInfo = $HostInvocation
    }
    else
    {
        $InvocationInfo = $MyInvocation
    }
    [String]$scriptDirectory = Split-Path -Path $InvocationInfo.MyCommand.Definition -Parent

    ## Dot source the required App Deploy Toolkit Functions
    try
    {
        [String]$moduleAppDeployToolkitMain = "$scriptDirectory\AppDeployToolkit\AppDeployToolkitMain.ps1"
        if (-not (Test-Path -LiteralPath $moduleAppDeployToolkitMain -PathType 'Leaf'))
        {
            throw "Module does not exist at the specified location [$moduleAppDeployToolkitMain]."
        }
        if ($DisableLogging)
        {
            . $moduleAppDeployToolkitMain -DisableLogging
        }
        else
        {
            . $moduleAppDeployToolkitMain
        }
    }
    catch
    {
        if ($mainExitCode -eq 0)
        {
            [Int32]$mainExitCode = 60008
        }
        Write-Error -Message "Module [$moduleAppDeployToolkitMain] failed to load: `n$($_.Exception.Message)`n `n$($_.InvocationInfo.PositionMessage)" -ErrorAction 'Continue'
        ## exit the script, returning the exit code to SCCM
        if (Test-Path -LiteralPath 'variable:HostInvocation')
        {
            $script:ExitCode = $mainExitCode; exit
        }
        else
        {
            exit $mainExitCode
        }
    }

    #endregion
    ##* Do not modify section above
    ##*===============================================
    ##* END VARIABLE DECLARATION
    ##*===============================================

    try
    {
        Start-AdditionalTestRecordingV3 -AppName $appName -DeploymentType $DeploymentType
    }
    catch
    {
        Write-Log -Message "Failed to initialize V3 recording integration. Deployment will continue. $($_.Exception.Message)" -Severity 2 -Source $deployAppScriptFriendlyName
    }
    if ($deploymentType -ine 'Uninstall' -and $deploymentType -ine 'Repair')
    {
        ##*===============================================
        ##* PRE-INSTALLATION
        ##*===============================================
        [String]$installPhase = 'Pre-Installation'

        ## Show Welcome Message, close Everything if required, allow up to 3 deferrals, and persist the prompt
        Show-InstallationWelcome -CloseApps 'Everything=Everything' -AllowDeferCloseApps -DeferTimes 3 -PersistPrompt -MinimizeWindows $false

        ## Show Progress Message (with the default message)
        Show-InstallationProgress

        ## <Perform Pre-Installation tasks here>


        ##*===============================================
        ##* INSTALLATION
        ##*===============================================
        [String]$installPhase = 'Installation'

        ## Handle Zero-Config MSI Installations
        if ($useDefaultMsi)
        {
            [Hashtable]$ExecuteDefaultMSISplat = @{ Action = 'Install'; Path = $defaultMsiFile }; if ($defaultMstFile)
            {
                $ExecuteDefaultMSISplat.Add('Transform', $defaultMstFile)
            }
            Execute-MSI @ExecuteDefaultMSISplat; if ($defaultMspFiles)
            {
                $defaultMspFiles | ForEach-Object { Execute-MSI -Action 'Patch' -Path $_ }
            }
        }

        ## <Perform Installation tasks here>

        Execute-Process -Path 'Everything-1.4.1.1032.x64-Setup.exe' -Parameters '/S'

        ##*===============================================
        ##* POST-INSTALLATION
        ##*===============================================
        [String]$installPhase = 'Post-Installation'

        ## <Perform Post-Installation tasks here>

        Remove-File -Path "$envCommonDesktop\Everything.lnk" -ContinueOnError $true

        ## Display a message at the end of the install
        if (-not $useDefaultMsi)
        {
            Show-InstallationPrompt -Message "$appName installation complete." -ButtonRightText 'OK' -Icon Information -NoWait -Timeout 5
        }
    }
    elseif ($deploymentType -ieq 'Uninstall')
    {
        ##*===============================================
        ##* PRE-UNINSTALLATION
        ##*===============================================
        [String]$installPhase = 'Pre-Uninstallation'

        ## Show Welcome Message, close Everything with a 60 second countdown before automatically closing
        Show-InstallationWelcome -CloseApps 'Everything=Everything' -CloseAppsCountdown 10

        ## Show Progress Message (with the default message)
        Show-InstallationProgress

        ## <Perform Pre-Uninstallation tasks here>


        ##*===============================================
        ##* UNINSTALLATION
        ##*===============================================
        [String]$installPhase = 'Uninstallation'

        ## Handle Zero-Config MSI Uninstallations
        if ($useDefaultMsi)
        {
            [Hashtable]$ExecuteDefaultMSISplat = @{ Action = 'Uninstall'; Path = $defaultMsiFile }; if ($defaultMstFile)
            {
                $ExecuteDefaultMSISplat.Add('Transform', $defaultMstFile)
            }
            Execute-MSI @ExecuteDefaultMSISplat
        }

        ## <Perform Uninstallation tasks here>

        Execute-Process -Path "$envProgramFiles\Everything\Uninstall.exe" -Parameters '/S' -ContinueOnError $true
        # Execute-Process -Path "$envProgramFilesX86\Everything\unins000.exe" -Parameters '/SILENT' -ContinueOnError $true

        ##*===============================================
        ##* POST-UNINSTALLATION
        ##*===============================================
        [String]$installPhase = 'Post-Uninstallation'

        ## <Perform Post-Uninstallation tasks here>

        if (-not $useDefaultMsi)
        {
            Show-InstallationPrompt -Message "$appName uninstallation complete." -ButtonRightText 'OK' -Icon Information -NoWait -Timeout 5
        }
    }
    elseif ($deploymentType -ieq 'Repair')
    {
        ##*===============================================
        ##* PRE-REPAIR
        ##*===============================================
        [String]$installPhase = 'Pre-Repair'

        ## Show Welcome Message, close Everything with a 60 second countdown before automatically closing
        Show-InstallationWelcome -CloseApps 'Everything=Everything' -CloseAppsCountdown 60

        ## Show Progress Message (with the default message)
        Show-InstallationProgress

        ## <Perform Pre-Repair tasks here>

        ##*===============================================
        ##* REPAIR
        ##*===============================================
        [String]$installPhase = 'Repair'

        ## Handle Zero-Config MSI Repairs
        if ($useDefaultMsi)
        {
            [Hashtable]$ExecuteDefaultMSISplat = @{ Action = 'Repair'; Path = $defaultMsiFile; }; if ($defaultMstFile)
            {
                $ExecuteDefaultMSISplat.Add('Transform', $defaultMstFile)
            }
            Execute-MSI @ExecuteDefaultMSISplat
        }
        ## <Perform Repair tasks here>

        Execute-Process -Path "$envProgramFiles\Everything\Uninstall.exe" -Parameters '/S' -ContinueOnError $true -ExitOnProcessFailure $false
        Execute-Process -Path 'Everything-1.4.1.1032.x64-Setup.exe' -Parameters '/S'

        ##*===============================================
        ##* POST-REPAIR
        ##*===============================================
        [String]$installPhase = 'Post-Repair'

        ## <Perform Post-Repair tasks here>

        Remove-File -Path "$envCommonDesktop\Everything.lnk" -ContinueOnError $true

    }
    ##*===============================================
    ##* END SCRIPT BODY
    ##*===============================================

    ## Call the Exit-Script function to perform final cleanup operations
    Stop-AdditionalTestRecordingV3 -AppName $appName -DeploymentType $DeploymentType
    Exit-Script -ExitCode $mainExitCode
}
catch
{
    [Int32]$mainExitCode = 60001
    [String]$mainErrorMessage = "$(Resolve-Error)"
    Write-Log -Message $mainErrorMessage -Severity 3 -Source $deployAppScriptFriendlyName
    try
    {
        Stop-AdditionalTestRecordingV3 -AppName $appName -DeploymentType $DeploymentType
    }
    catch
    {
        Write-Log -Message "Failed to stop V3 recording. $($_.Exception.Message)" -Severity 2 -Source $deployAppScriptFriendlyName
    }
    Show-DialogBox -Text $mainErrorMessage -Icon 'Stop'
    Exit-Script -ExitCode $mainExitCode
}
