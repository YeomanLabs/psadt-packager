# PSADT Packager

A standard packager for Intune and ConfigMgr built on [PSAppDeployToolkit v4](https://psappdeploytoolkit.com). Point it at an installer, fill in (or accept) the install, uninstall and detection settings, and it produces a complete, consistent package every time.

```
<Destination>\<Vendor>_<Name>_<Version>\
    Package\                      PSADT v4 toolkit + generated Invoke-AppDeployToolkit.ps1
        Files\                    installer, transforms, scripts
        SupportFiles\             anything else the deployment needs
    Detect-<Name>.ps1             Intune custom detection script
    Package.json                  the definition - reopen it to change anything and rebuild
    README.md                     Intune Win32 app settings for this package
    IntuneApp.json                the exact Win32 app body that gets posted to Graph
    Intune\<Vendor>_<Name>_<Version>.intunewin   (optional, via IntuneWinAppUtil.exe)
```

Everything is one file, `PsadtPackager.ps1`. No install, no build step. Runs on Windows PowerShell 5.1 and PowerShell 7.

## Run

```powershell
.\PsadtPackager.ps1
```

Headless rebuild from a saved definition (CI, bulk re-packaging after a toolkit update):

```powershell
.\PsadtPackager.ps1 -Definition .\examples\GitHub-CLI.json -NoGui -Force
```

The first build downloads PSAppDeployToolkit from the PowerShell Gallery into `%LOCALAPPDATA%\PsadtPackager\Modules` (or uses an installed copy). The toolkit shipped inside each package is the exact version that generated it.

## Workflow

1. **Application**: click *Read metadata from installer*. MSI, EXE, MSIX/AppX and PS1 are supported. Vendor, name, version, product code, silent switches, uninstall method and detection rule are filled from the file.
2. **Source files**: add anything else the install needs (transforms, config, extra installers). Folders can be copied as a subfolder or flattened.
3. **Install**: install type, arguments, transforms, processes to close, exit codes, dialogs, plus pre/post PowerShell that runs inside the toolkit session.
4. **Uninstall**: MSI product code, installed app by name (`Uninstall-ADTApplication`), uninstaller EXE on the device, script, MSIX, custom or none.
5. **Detection**: MSI product code, registry DisplayName (exact / wildcard / regex), file (optionally version), MSIX, or paste your own. *Run preview on this PC* executes the generated script locally.
6. **Build**: destination, Intune deploy mode for the generated command lines, optional `.intunewin`.
7. **Intune**: sign in and publish. Every field is derived from the tabs above; type over anything you want to change.

`File > Save definition` writes the JSON so the package is reproducible. `Package.json` is also written next to every generated package.

## What the generated deployment script looks like

The generator only writes the `Variables` and `Functions` sections of `Invoke-AppDeployToolkit.ps1`. The header, parameter block and bootstrap come verbatim from the template produced by `New-ADTTemplate`, so the file always matches the toolkit version it ships with.

| Install type | Generated call |
| --- | --- |
| MSI | `Start-ADTMsiProcess -Action Install -FilePath … [-Transforms …] [-AdditionalArgumentList …]` |
| EXE | `Start-ADTProcess -FilePath … -ArgumentList '…' -WindowStyle Hidden` |
| PowerShell script | `& "$($adtSession.DirFiles)\Install.ps1" <args>` (in-process, full toolkit access) |
| MSIX / AppX | `Add-AppxProvisionedPackage -Online -PackagePath … -SkipLicense` |
| Custom | your code becomes the Install phase |

Silent-switch presets are provided for Inno Setup, NSIS, InstallShield, WiX Burn, Squirrel, InstallAware, Advanced Installer, install4j, InstallBuilder, InstallAnywhere, Qt IFW, Wise, Setup Factory and 7-Zip/WinRAR self-extractors; the engine is detected from the EXE where possible, and the log lists any known switches found as strings inside the binary.

## Finding switches by running the installer

Signature detection is a guess. *Find switches in Sandbox...* on the Install tab proves it: for each candidate
switch set it boots a fresh Windows Sandbox, maps the installer folder read-only, runs `setup.exe /?` and
captures the help dialog (UI Automation) or console output, then runs the candidate while watching the process
tree for any window that stays up. It snapshots the Uninstall registry before and after, so a successful run
reports the real `DisplayName`, `DisplayVersion`, `Publisher` and `UninstallString`/`QuietUninstallString`,
runs your detection script, then runs the uninstall and confirms the key disappears.

The first candidate that installs silently wins. One click applies it: install arguments, a verified uninstall
command, an exact-match registry detection rule, and vendor/version if the Application tab had them blank.
Candidates are ordered: your current arguments, the detected engine's preset, generic switches whose strings
appear in the binary, then the rest (four per run by default; each takes roughly one to three minutes).

Nothing runs on the packaging PC. Requires Windows Sandbox (Pro/Enterprise/Education with virtualisation):
`Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM`. Run folders with
`probe.log`, `result-N.json` and the `.wsb` live under `%LOCALAPPDATA%\PsadtPackager\Sandbox\`.

## Detection scripts

Generated scripts follow the Intune contract (exit 0 and STDOUT = detected). Registry methods enumerate HKLM 64-bit, HKLM 32-bit and HKCU, and version comparison normalises `1.2.3` vs `1.2.3.0` so a minimum-version rule behaves as "this version or newer".

## Publishing to Intune

The Intune tab creates the Win32 app for you. Nothing is retyped - every setting comes from the
definition you already filled in:

| Win32 app setting | Comes from |
| --- | --- |
| Name / App version | Application tab (`<Name> <Version>`) |
| Publisher, Developer, Owner | Application tab vendor and author |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode <mode>` |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode <mode>` |
| Setup file | `Invoke-AppDeployToolkit.exe` |
| Detection rule | the generated `Detect-<Name>.ps1`, uploaded as a 64-bit script rule |
| Return codes | Install tab success and reboot codes, plus 1618/60012 retry and 1602 failed |
| Requirements | Application tab architecture, plus the minimum OS you pick |
| Install behavior | System or user, restart behavior, max run time |

Anything you type into a field on the Intune tab overrides the derived value; *Reset to auto values*
puts it back. *Preview app JSON* shows the exact body that will be sent, and the same body is written
to `IntuneApp.json` beside every generated package.

If you would rather use the portal wizard, the built `.intunewin` has its metadata name set to the app's
display name, so *Name* and *Description* come in as `7-Zip 26.03` instead of `Invoke-AppDeployToolkit.exe`.
That is the only field the wizard reads from a command-line `.intunewin`; the rest is in the package
`README.md` to copy from, or one click on *Publish*.

Sign-in uses the device code flow - no modules to install. By default it signs in with the Microsoft
Graph PowerShell public client, which needs `DeviceManagementApps.ReadWrite.All`; point it at your own
app registration if you would rather scope it yourself. Publishing creates the app and uploads the
`.intunewin`; **assignments are deliberately left to you**.

Headless, for CI:

```powershell
.\PsadtPackager.ps1 -Definition .\Package.json -NoGui -Force -Publish -TenantId contoso.com
```

Use `-DeployMode Auto` (or omit it) for Available assignments where you want the close-apps and defer dialogs.

## Repository layout

| Path | Purpose |
| --- | --- |
| `PsadtPackager.ps1` | GUI, definition model, code generators, headless build |
| `examples\` | Sample definitions (edit the `Sources.Files` paths to match your share) |

## Notes

* Keep destinations short (for example `C:\Packages`). Windows PowerShell 5.1 cannot copy the toolkit tree beyond MAX_PATH; the build checks this up front.
* `.intunewin` building needs `IntuneWinAppUtil.exe`. Use the *Download* button on the Build tab or point to an existing copy.
* Settings (destination, tool path, author, tenant) persist in `%LOCALAPPDATA%\PsadtPackager\settings.json`. No tokens are written to disk - sign-in lasts for the session.
* Publishing always creates a new app. If one with the same name already exists you get a warning in the log, not a silent overwrite.
