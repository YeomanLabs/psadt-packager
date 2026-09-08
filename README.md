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
6. **Build**: destination, Intune deploy mode for the README command lines, optional `.intunewin`.

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

Silent-switch presets are provided for Inno Setup, NSIS, InstallShield, WiX Burn, Squirrel, InstallAware and Advanced Installer, and the engine is detected from the EXE where possible.

## Detection scripts

Generated scripts follow the Intune contract (exit 0 and STDOUT = detected). Registry methods enumerate HKLM 64-bit, HKLM 32-bit and HKCU, and version comparison normalises `1.2.3` vs `1.2.3.0` so a minimum-version rule behaves as "this version or newer".

## Intune settings

Each package's `README.md` lists the values to enter in the Win32 app wizard:

| Setting | Value |
| --- | --- |
| Install command | `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent` |
| Uninstall command | `Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent` |
| Install behavior | System |
| Detection rule | Custom script: `Detect-<Name>.ps1` |
| Return codes | 0 success, 3010 soft reboot, 1641 hard reboot, 1618 retry, 60012 deferred |

Use `-DeployMode Auto` (or omit it) for Available assignments where you want the close-apps and defer dialogs.

## Repository layout

| Path | Purpose |
| --- | --- |
| `PsadtPackager.ps1` | GUI, definition model, code generators, headless build |
| `examples\` | Sample definitions (edit the `Sources.Files` paths to match your share) |

## Notes

* Keep destinations short (for example `C:\Packages`). Windows PowerShell 5.1 cannot copy the toolkit tree beyond MAX_PATH; the build checks this up front.
* `.intunewin` building needs `IntuneWinAppUtil.exe`. Use the *Download* button on the Build tab or point to an existing copy.
* Settings (destination, tool path, author) persist in `%LOCALAPPDATA%\PsadtPackager\settings.json`.
