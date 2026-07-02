# Example - Digiexam MSI

## Description

This is an example script to deploy Digiexam with MSI. In this test variant, the package is referenced as `Digiexam_26.1.24_x64_en-US.msi`.

## Pre-Installation

```ps
## Show Welcome Message, close Digiexam if required, allow up to 3 deferrals, and persist the prompt
Show-InstallationWelcome -CloseApps 'digiexam=Digiexam' -AllowDeferCloseApps -DeferTimes 3 -PersistPrompt -MinimizeWindows $false
```

If Digiexam is running, the user will be prompted to either close the app or defer the installation.

## Installation

```ps
Execute-MSI -Action Install -Path 'Digiexam_26.1.24_x64_en-US.msi'
```

Installs the Digiexam MSI from the local package path.

## Post-Installation

```ps
## No app-specific post-install customization required for this MSI test sample.
```

No additional post-install actions are required in this sample.

## Uninstallation

```ps
Show-InstallationWelcome -CloseApps 'digiexam=Digiexam' -CloseAppsCountdown 60
Execute-MSI -Action Uninstall -Path 'Digiexam_26.1.24_x64_en-US.msi'
```

The uninstall flow prompts for Digiexam closure, then removes the MSI package.

## Repair

```ps
Show-InstallationWelcome -CloseApps 'Digiexam=Digiexam' -CloseAppsCountdown 60
Execute-MSI -Action Repair -Path 'Digiexam_26.1.24_x64_en-US.msi' -RepairFromSource $true
```

The repair flow closes Digiexam if needed and runs MSI repair from source.
