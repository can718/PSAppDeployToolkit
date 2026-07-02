# Example - Everything

## Description

This is an example script to deploy Everything. You will need to add the rest of the toolkit files, as well as `Everything-1.4.1.1032.x64-Setup.exe` in the Files folder.

## Pre-Installation

```ps
## Show Welcome Message, close Everything if required, allow up to 3 deferrals, and persist the prompt
Show-InstallationWelcome -CloseApps 'Everything=Everything' -AllowDeferCloseApps -DeferTimes 3 -PersistPrompt -MinimizeWindows $false
```

If Everything is running, the user will be prompted to either close the app or defer the installation.

## Installation

```ps
Execute-Process -Path 'Everything-1.4.1.1032.x64-Setup.exe' -Parameters '/S'
```

Runs the setup with the required silent switch.

## Post-Installation

```ps
Remove-File -Path "$envCommonDesktop\Everything.lnk" -ContinueOnError $true
```

This removes the desktop shortcut if present.
