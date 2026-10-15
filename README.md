# PSADT Packager

A standard packager for Intune and ConfigMgr built on [PSAppDeployToolkit v4](https://psappdeploytoolkit.com). Drop in an installer, script, zip or folder and it works out the install, uninstall and detection on its own: it runs the thing in Windows Sandbox as SYSTEM, builds the package, then tests the finished package end to end. Or fill in the tabs yourself; either way you get a complete, consistent package every time.

```
<Destination>\<Vendor>_<Name>_<Version>\
    Package\                      PSADT v4 toolkit + generated Invoke-AppDeployToolkit.ps1
        Files\                    installer, transforms, scripts
        SupportFiles\             anything else the deployment needs
    Detect-<Name>.ps1             Intune custom detection script
    Package.json                  the definition - reopen it to change anything and rebuild
    README.md                     Intune Win32 app settings for this package
    IntuneApp.json                the exact Win32 app body that gets posted to Graph
    AutoPackage-Report.md         auto-package only: what was decided, why, and what the sandbox proved
    Validation\                   auto-package only: toolkit logs from the end-to-end test
    Intune\<Vendor>_<Name>_<Version>.intunewin   (via IntuneWinAppUtil.exe)
```

Everything is one file, `PsadtPackager.ps1`. No install, no build step. Runs on Windows PowerShell 5.1 and PowerShell 7.

## Run

```powershell
.\PsadtPackager.ps1
```

Then drop an installer, script, `.zip` or folder anywhere on the window (or click *Auto-package...* on the Application tab).

Headless, straight from an installer (CI, bulk packaging):

```powershell
.\PsadtPackager.ps1 -InstallerPath C:\Sources\npp.8.9.8.1.Installer.x64.exe -NoGui -Destination C:\Packages
```

Headless rebuild from a saved definition (bulk re-packaging after a toolkit update):

```powershell
.\PsadtPackager.ps1 -Definition .\examples\GitHub-CLI.json -NoGui -Force
```

The first build downloads PSAppDeployToolkit from the PowerShell Gallery into `%LOCALAPPDATA%\PsadtPackager\Modules` (or uses an installed copy). The toolkit shipped inside each package is the exact version that generated it.

## Auto-package

What you can drop in, and how it is treated:

| Input | Treated as |
| --- | --- |
| `.msi` | Windows Installer; product code, version and architecture from the MSI. `.mst` files next to it are applied as transforms. |
| `.exe` | Installer; the engine (Inno, NSIS, InstallShield, WiX Burn, ...) is recognised and its silent switches proven in the sandbox. |
| `.msix` / `.appx` (bundles) | Provisioned for all users. |
| `.ps1`, `.cmd`, `.bat`, `.vbs` | Script install; detection and uninstall are derived from what the script creates. |
| Folder | Searched for the entry point: `install.*`/`setup.*` scripts first, then a single MSI, then `setup.exe`, then any recognisable installer. An `uninstall.*` / `remove.*` script is used for the uninstall. A folder of program files with no installer is a portable app. |
| `.zip` | Extracted, then treated like a folder. |

Then, for installers and scripts:

1. **Read the file**: name, vendor, version and architecture from the MSI, version resource or file/folder name (versions, `(x64)` and e-mail/URL vendors are cleaned up).
2. **Run it in Windows Sandbox as SYSTEM**, like Intune does, one fresh sandbox per attempt. For an EXE it tries the engine's switches first, then switches found inside the binary, and stops at the first that installs silently. It records everything the install created: uninstall entries, folders, shortcuts, registry keys, services and scheduled tasks, and the help text the installer shows for `/?`.
3. **Decide**: detection from the uninstall entry the installer registered (version-tolerant when the name carries the version), otherwise the main program file, a service or a registry key. Uninstall from the registered command (proven in the same sandbox), a shipped uninstall script, uninstall-by-name, or generated clean-up of what the install created. Publisher and version come from what was registered.
4. **Build** the package and `.intunewin` (IntuneWinAppUtil.exe is downloaded if needed).
5. **Test the package** in a fresh sandbox as SYSTEM: install, detection, uninstall, detection again. Anything left behind after the uninstall is listed.

`AutoPackage-Report.md` shows each setting, how it was determined, the sandbox attempts and the end-to-end result. Status is **Validated** (all four steps passed), **Built** (not tested end to end) or **Needs attention** (no silent switches found, the test failed, or a per-user installer that lands in the SYSTEM profile). Headless exit codes: 0 validated or built, 2 needs attention, 1 error. `-NoSandbox` packages from the file alone; `-SkipValidation` skips step 5.

MSI and MSIX are fully described by the file, so they skip step 2 and go straight to the end-to-end test.

Limits worth knowing:

* **Per-user installers** (many Electron / Squirrel apps) install into the profile of whoever runs them. As SYSTEM that is the system profile, so the report flags them; look for the vendor's machine-wide installer (often an MSI) or deploy in the user context.
* **Installers that need a licence key, a server name or a reboot mid-way** cannot be guessed. The probe reports which switches it tried and the installer's own `/?` help text so you can finish it on the Install tab.
* **Generated uninstalls** (scripts and installers that register no uninstaller) remove exactly what the sandbox saw being created. Review them before production use; the end-to-end test proves they run cleanly, not that nothing else needed removing.
* **VBScript installers (`.vbs`) cannot be observed** on current Windows: VBScript is an optional component Microsoft is retiring, and the Windows Sandbox image does not include it (nor can it be added there). The report says so; set detection and uninstall by hand, or better, convert the script to PowerShell before VBScript disappears from your devices too.
* **Every MSI install inside Windows Sandbox pauses for about two minutes** at the Windows Installer's software-restriction check (measured: 7-Zip's MSI takes ~121 s there, every time, with or without networking). It is a sandbox quirk, not the package, but it makes MSI-based apps slower to test: a WiX bundle with two MSIs takes ~4 minutes per run. The stuck rules allow for it.

## Workflow

1. **Application**: *Auto-package...* does everything above. *Read metadata from installer* only reads the file (MSI, EXE, MSIX/AppX, PS1, CMD, BAT, VBS) and fills vendor, name, version, product code, silent switches, uninstall method and detection for you to finish by hand.
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
| PowerShell script | `& "$($adtSession.DirFiles)\Install.ps1" <args>` from the script's folder (in-process, full toolkit access; a failing exit code fails the deployment) |
| Batch / VBScript | `Start-ADTProcess` running `cmd.exe /c` or `cscript.exe //B` from the script's folder |
| MSIX / AppX | `Add-AppxProvisionedPackage -Online -PackagePath … -SkipLicense` |
| Custom | your code becomes the Install phase |

Silent-switch presets are provided for Inno Setup, NSIS, InstallShield, WiX Burn, Squirrel, InstallAware, Advanced Installer, install4j, InstallBuilder, InstallAnywhere, Qt IFW, Wise, Setup Factory and 7-Zip/WinRAR self-extractors; the engine is detected from the EXE where possible, and the log lists any known switches found as strings inside the binary.

## Finding switches by running the installer

Signature detection is a guess. *Find switches in Sandbox...* on the Install tab (and auto-package) proves it:
for each candidate switch set it starts a fresh, headless Windows Sandbox (no window opens), copies the installer in
and runs it **as SYSTEM**, the account Intune uses. It runs `setup.exe /?` first and captures the help dialog's text
or console output, then runs the candidate while watching the whole process tree. SYSTEM has no visible desktop,
so an installer waiting for a click just sits there: a run counts as stuck when the tree (plus anything it started,
such as the Windows Installer service) goes idle for 30 seconds while it shows a window with controls (quiet-mode
windows that are created but never shown don't count), or stays idle for five minutes without one. It snapshots
the system before and after, so a successful run reports the real uninstall entry (`DisplayName`,
`DisplayVersion`, `Publisher`, `UninstallString`/`QuietUninstallString`) and everything else the install created,
runs your detection script, then runs the uninstall and confirms the entry is gone and detection is negative.

The first candidate that installs silently wins. One click applies it: install arguments, a verified uninstall
command, a registry detection rule, and vendor/version if the Application tab had them blank. Candidates are
ordered: your current arguments, the detected engine's preset, generic switches whose strings appear in the binary,
then the rest (four per run by default; each takes about a minute). Scripts are run once to see what they create.

Nothing runs on the packaging PC. Requires Windows Sandbox with its command-line tool `wsb.exe`, which ships with
Windows 11 24H2 and later (Pro/Enterprise/Education, virtualisation on). Enable it in *Windows Features*, or from an
elevated **Windows PowerShell 5.1** prompt (the DISM cmdlets fail with "Class not registered" in the Store build of
PowerShell 7): `Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM`, then reboot. Only
one sandbox can run at a time. Run folders with `config.json`, `probe.log` and `result.json` live under
`%LOCALAPPDATA%\PsadtPackager\Sandbox\`.

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
| `PsadtPackager.ps1` | GUI, definition model, code generators, sandbox probe, auto-package, headless build |
| `examples\` | Sample definitions (edit the `Sources.Files` paths to match your share) |
| `tests\Test-PsadtPackager.ps1` | Offline regression tests (no sandbox or network): name/version clean-up, input classification, probe decisions, and that every generated script parses. Run it under both PowerShell 5.1 and 7. |

## Notes

* Keep destinations short (for example `C:\Packages`). Windows PowerShell 5.1 cannot copy the toolkit tree beyond MAX_PATH; the build checks this up front.
* `.intunewin` building needs `IntuneWinAppUtil.exe`. Use the *Download* button on the Build tab or point to an existing copy.
* Settings (destination, tool path, author, tenant) persist in `%LOCALAPPDATA%\PsadtPackager\settings.json`. No tokens are written to disk - sign-in lasts for the session.
* Publishing always creates a new app. If one with the same name already exists you get a warning in the log, not a silent overwrite.
