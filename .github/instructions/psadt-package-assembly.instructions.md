---
name: "PSADT Package Assembly"
description: "Use when changing PSADT V3/V4 template artifact downloads, Additional or Intune package generation, TestApps metadata, deployment scripts, installer staging, SCCM content, or Intune Win32 apps."
applyTo: ".github/workflows/run-additional-tests*.yml,.github/workflows/run-intune-tests*.yml,src/Tests/Additional/**,src/Tests/Intune/**,src/Tests/_Shared/**,src/Tests/V3/**,src/Tests/V4/**"
---
# PSADT Package Assembly Rules

## Sources Of Truth

- Treat the downloaded or locally exported V3/V4 template as the generic PSADT runtime base, not as a complete application package.
- Keep shared application and deployment-platform metadata in `src/Tests/_Shared/TestApps.ps1`: template version, application identity, installer source, content subpath, install/uninstall commands, and detection logic.
- Keep application-specific deployment behavior in `src/Tests/V3/<App>/Deploy-Application.ps1` for V3 or `src/Tests/V4/<App>/New-ADTTemplate.params.ps1` for V4.
- Use `PSADT_TEMPLATE_V3_DIR` and `PSADT_TEMPLATE_V4_DIR` as the resolved template roots supplied by the workflow. Do not hard-code an extracted artifact directory in test code.
- Template artifacts contain only the generic PSADT base. Continue obtaining application installers from `InstallerSourceFile`, V4 `Files`, or the existing test-asset preparation flow; do not expect app installers inside the template artifact.

## Assembly Flow

1. Acquire the V3 and V4 template artifacts, verify their expected SHA-256 hashes when using upstream downloads, and extract them to stable template directories.
2. Load the application entry from `TestApps.ps1` and resolve defaults with the existing shared helpers.
3. Build an application test context containing the template roots, source script or parameter folder, local package directory, SCCM content UNC, application identity, and Configuration Manager connection details.
4. Assemble the package with the version-specific path below.
5. Inject the test recording extension through the existing Additional or Intune helper rather than modifying the upstream template.
6. For Additional tests, verify the local package and SMB content path before creating the SCCM application/deployment type. For Intune tests, wrap the assembled directory with IntuneWinAppUtil before uploading and assigning the Win32 app.

## V3 Copy-And-Overlay Path

- For Additional tests, use `Initialize-PSADTPackageDirectoryFromTemplate`; for Intune tests, use `New-IntuneTestWorkDirV3`. Both must copy the contents of the resolved V3 template into a clean application package directory.
- Use `Update-PSADTPackageDeployScript` to overlay the application's `Deploy-Application.ps1` at the package root.
- Use `Copy-PSADTPackageInstallerToFiles` to place the MSI or EXE in the resolved package `Files` directory.
- Preserve the template directory shape, including `AppDeployToolkit`; avoid introducing an extra nested template folder when copying.

Expected result:

```text
<PackageDir>/
  Deploy-Application.ps1
  Deploy-Application.exe
  AppDeployToolkit/
  Files/<installer>
  SupportFiles/<recording extension>
```

## V4 Generator Path

- For Additional tests, use `Initialize-PSADTPackageDirectoryFromTemplateV4`; for Intune tests, use `New-IntuneTestWorkDirV4`. Do not implement V4 as a raw copy of the downloaded template.
- Import `PSAppDeployToolkit.psd1` from the resolved V4 template and call the shared `Invoke-ADTTemplateRunner`.
- Load the application's `New-ADTTemplate.params.ps1`, then override `Destination`, `Name`, `Files`, and optional `SupportFiles` with runtime values before calling `New-ADTTemplate`.
- Keep PSADT session properties and pre/install/post/uninstall/repair script blocks in the per-application parameter file.
- Derive the destination parent and package name with `Split-Path` before generation; do not require `PackageDir` to exist before `New-ADTTemplate` runs.

Expected result:

```text
<PackageDir>/
  Invoke-AppDeployToolkit.ps1
  Invoke-AppDeployToolkit.exe
  PSAppDeployToolkit/
  Files/<installer>
  SupportFiles/<recording extension>
```

## Package Content Versus Platform Metadata

- Package content includes the PSADT runtime, generated or overlaid deployment logic, installer files, session properties used by the script, and recording extension.
- Platform metadata includes application name, publisher/vendor, version, install/uninstall command, detection rules, description, assignments, and SCCM-specific deployment type/content UNC values.
- Pass platform metadata to the existing SCCM application/deployment-type helpers or Intune Win32 app helpers. Do not assume every value in `TestApps.ps1` must be serialized into the package directory.
- Keep the install/uninstall commands aligned with the actual V3 or V4 launcher generated in the package.

## Change And Validation Rules

- Preserve the original local-build workflow unless a task explicitly requests changing it; keep upstream-artifact behavior in its dedicated workflow.
- When changing artifact names, run IDs, commits, or checksums, verify them against GitHub artifact metadata before editing pinned values.
- When changing template acquisition, package assembly helpers, app metadata fields, installer staging, or platform publishing behavior, update this instruction file in the same change if its documented flow is no longer accurate.
- After changing one application, validate only that application's package first: required launcher, runtime directory, deployment script/session values, installer under `Files`, and recording extension.
- Then validate its platform arguments: install/uninstall command, detection rule, application identity, and either SCCM content/deployment type values or Intune packaging/upload/assignment values.
- Run focused Pester discovery/execution for the affected application before broad Additional or Intune test runs.