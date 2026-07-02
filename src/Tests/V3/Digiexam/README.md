# Example - Firefox MSI

## Description

This is an example script to deploy Firefox with MSI. In this test variant, the installer is referenced from `C:\tools\intune\Firefox Setup 152.0.4.msi`.

## Pre-Installation

```ps
## Show Welcome Message, close Firefox if required, allow up to 3 deferrals, and persist the prompt
Show-InstallationWelcome -CloseApps 'firefox=Firefox' -AllowDeferCloseApps -DeferTimes 3 -PersistPrompt -MinimizeWindows $false
```

If Firefox is running, the user will be prompted to either close the app or defer the installation.

## Installation

```ps
Execute-MSI -Action Install -Path 'C:\tools\intune\Firefox Setup 152.0.4.msi'
```

Installs the MSI from the local package path.

## Post-Installation

```ps
## No app-specific post-install customization required for this MSI test sample.
```

No additional post-install actions are required in this sample.
