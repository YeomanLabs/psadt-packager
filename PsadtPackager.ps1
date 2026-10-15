<#
.SYNOPSIS
    PSADT Packager - GUI and headless builder for PSAppDeployToolkit v4 packages.

.DESCRIPTION
    Turns a package definition (built in the GUI or loaded from JSON) into a complete
    PSAppDeployToolkit v4 package ready for Intune / ConfigMgr:

      <Destination>\<Vendor>_<Name>_<Version>\
          Package\                      PSADT v4 toolkit + generated Invoke-AppDeployToolkit.ps1
              Files\                    your installer, transforms, scripts
              SupportFiles\             anything else the deployment needs
          Detect-<Name>.ps1             Intune custom detection script
          Package.json                  the definition (rebuild any time)
          README.md                     Intune Win32 app settings for this package
          Intune\<Vendor>_<Name>_<Version>.intunewin   (optional)

    The PSAppDeployToolkit module is taken from an installed copy, or downloaded once from
    the PowerShell Gallery into %LOCALAPPDATA%\PsadtPackager\Modules.

.PARAMETER Definition
    Path to a Package.json definition. With -NoGui the package is built immediately;
    without -NoGui the GUI opens with the definition loaded.

.PARAMETER InstallerPath
    Auto-package: an installer (.msi, .exe, .msix/.appx), a script (.ps1, .cmd, .bat, .vbs), a .zip or a
    folder. The packager reads it, runs it in Windows Sandbox as SYSTEM to work out the silent switches,
    uninstall and detection, builds the package, tests it end to end in a fresh sandbox and writes
    AutoPackage-Report.md next to it. With -NoGui it runs headlessly; without, the GUI opens and starts it.

.PARAMETER NoSandbox
    Auto-package from the file alone; nothing is run (switches, uninstall and detection are guesses).

.PARAMETER SkipValidation
    Auto-package without the final end-to-end test of the built package.

.PARAMETER NoGui
    Build headlessly from -Definition or -InstallerPath (for CI / repeatable rebuilds).
    Exit code 0 = built (and validated when a sandbox was available), 1 = error, 2 = built or attempted
    but it needs attention (see AutoPackage-Report.md).

.PARAMETER Destination
    Overrides Output.Destination from the definition.

.PARAMETER Force
    Overwrite an existing Package folder in headless mode.

.PARAMETER Publish
    After building, sign in to Microsoft Graph (device code) and create the Intune Win32 app,
    uploading the .intunewin and filling in every setting the definition already knows.

.PARAMETER TenantId
    Tenant id or domain for the Graph sign-in. Defaults to the definition, then to 'organizations'.

.PARAMETER ClientId
    App registration to sign in with. Defaults to the Microsoft Graph PowerShell public client.

.EXAMPLE
    .\PsadtPackager.ps1

.EXAMPLE
    .\PsadtPackager.ps1 -Definition .\examples\Notepad++.json -NoGui -Force

.EXAMPLE
    .\PsadtPackager.ps1 -InstallerPath C:\Sources\npp.8.9.8.1.Installer.x64.exe -NoGui -Destination C:\Packages

.NOTES
    Works on Windows PowerShell 5.1 and PowerShell 7 (Windows only - WPF).
#>
#Requires -Version 5.1
[CmdletBinding()]
param
(
    [Parameter(Position = 0)]
    [string]$Definition,

    [Alias('Path')]
    [string]$InstallerPath,

    [switch]$NoSandbox,

    [switch]$SkipValidation,

    [switch]$NoGui,

    [string]$Destination,

    [switch]$Force,

    [switch]$Publish,

    [string]$TenantId,

    [string]$ClientId
)

# Windows PowerShell started from a PowerShell 7 session (other than by pwsh itself, which cleans this up) inherits
# PowerShell 7's module folders, and then every module import fails with "Error in TypeData ... is already present".
# Restart once with the module path a process started from Explorer gets, passing the same arguments and exit code.
if ($PSVersionTable.PSEdition -eq 'Desktop' -and -not $env:PSADT_PACKAGER_RELAUNCHED)
{
    $foreignModules = @("$env:PSModulePath" -split ';' | Where-Object { $_ -and $_ -notmatch 'WindowsPowerShell' -and ($_ -match '\\PowerShell\\' -or $_ -match 'microsoft\.powershell_') })
    if ($foreignModules.Count -gt 0)
    {
        $env:PSADT_PACKAGER_RELAUNCHED = '1'
        $env:PSModulePath = (@([Environment]::GetEnvironmentVariable('PSModulePath', 'Machine'), [Environment]::GetEnvironmentVariable('PSModulePath', 'User')) | Where-Object { $_ }) -join ';'
        $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
        foreach ($kv in $PSBoundParameters.GetEnumerator())
        {
            if ($kv.Value -is [System.Management.Automation.SwitchParameter]) { if ($kv.Value.IsPresent) { $relaunch += "-$($kv.Key)" } }
            else { $relaunch += "-$($kv.Key)"; $relaunch += ('"{0}"' -f $kv.Value) }
        }
        $child = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $relaunch -NoNewWindow -Wait -PassThru
        exit $child.ExitCode
    }
}

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:PackagerVersion = '1.2.0'
$script:AppDataDir      = Join-Path $env:LOCALAPPDATA 'PsadtPackager'
$script:ModuleCache     = Join-Path $script:AppDataDir 'Modules'
$script:SettingsPath    = Join-Path $script:AppDataDir 'settings.json'
$script:IntuneWinUrl    = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe'
$script:LogSink         = { param($Line, $Level) if ($Level -eq 'Error') { Write-Host $Line -ForegroundColor Red } elseif ($Level -eq 'Warn') { Write-Host $Line -ForegroundColor Yellow } else { Write-Host $Line } }

$script:InstallTypeCodes   = @('MSI', 'EXE', 'Script', 'MSIX', 'Custom')
$script:InstallTypeLabels  = @('MSI (Start-ADTMsiProcess)', 'EXE / setup.exe (Start-ADTProcess)', 'Script in Files\ (.ps1, .cmd, .bat, .vbs)', 'MSIX / AppX (provisioned)', 'Custom PowerShell (you write the Install phase)')
$script:UninstallTypeCodes = @('MSI', 'Name', 'EXE', 'Script', 'MSIX', 'Custom', 'None')
$script:UninstallTypeLabels= @('MSI product code (Start-ADTMsiProcess)', 'Installed app by name (registered uninstaller)', 'Uninstaller EXE on the device (Start-ADTProcess)', 'Script in Files\ (.ps1, .cmd, .bat, .vbs)', 'MSIX / AppX (remove provisioned + installed)', 'Custom PowerShell (you write the Uninstall phase)', 'None')
$script:DetectTypeCodes    = @('MSI', 'Registry', 'File', 'MSIX', 'Script')
$script:DetectTypeLabels   = @('MSI product code in Uninstall registry', 'Uninstall registry entry by DisplayName', 'File exists (optionally version)', 'MSIX / AppX package', 'Custom script (paste your own)')
$script:MatchModeCodes     = @('Exact', 'Wildcard', 'Regex')
$script:AppTypeCodes       = @('All', 'MSI', 'EXE')
$script:ArchChoices        = @('', 'x64', 'x86', 'ARM64')
$script:DeployModeChoices  = @('Silent', 'Auto', 'Interactive', 'NonInteractive')
$script:RunAsChoices       = @('system', 'user')
$script:RunAsLabels        = @('System (device context)', 'User (logged-on user)')
$script:RestartChoices     = @('basedOnReturnCode', 'allow', 'suppress', 'force')
$script:RestartLabels      = @('Determine behavior based on return codes', 'App install may force a device restart', 'No specific action', 'Intune will force a mandatory device restart')
$script:MinOsCodes         = @('v10_1607', 'v10_1703', 'v10_1709', 'v10_1803', 'v10_1809', 'v10_1903', 'v10_1909', 'v10_2004', 'v10_2H20', 'v10_21H1')
$script:MinOsLabels        = @('Windows 10 1607', 'Windows 10 1703', 'Windows 10 1709', 'Windows 10 1803', 'Windows 10 1809', 'Windows 10 1903', 'Windows 10 1909', 'Windows 10 2004', 'Windows 10 20H2', 'Windows 10 21H1 or later')
$script:ArchChoicesIntune  = @('', 'x64', 'x86,x64', 'x86', 'arm64')
# Tried in the sandbox, after the current arguments and the detected engine's preset. Order = most common first.
$script:GenericSilentCandidates = @('/S', '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-', '/quiet /norestart', '/silent', '/silent /install','/s', '/qn /norestart', '-silent', '--silent', '/q', '-q', '/s /v"/qn REBOOT=ReallySuppress"', '/exenoui /qn', '/passive /norestart', '-y', '--mode unattended')
# Tokens looked for as literal strings inside an EXE; a hit promotes the matching candidate.
$script:SwitchVocabulary = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/SILENT', '/NORESTART', '/quiet', '/passive', '/norestart', '/qn', '/exenoui', '--silent', '-silent', '/silent', '--quiet', '--mode', 'unattended', '/unattended', '/S', '/s', '-q', '-y', '/q', '-i silent', '--confirm-command', '--accept-licenses', '-overwrite')
$script:GraphToken         = $null
$script:GraphPromptSink    = $null

$script:SilentPresets = [ordered]@{
    'Inno'              = @{ Label = 'Inno Setup';             Install = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'; Uninstall = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
    'NSIS'              = @{ Label = 'NSIS (Nullsoft)';        Install = '/S';                                            Uninstall = '/S' }
    'InstallShield'     = @{ Label = 'InstallShield';          Install = '/s /v"/qn REBOOT=ReallySuppress"';               Uninstall = '/s /x /v"/qn REBOOT=ReallySuppress"' }
    'WiX'               = @{ Label = 'WiX Burn bundle';        Install = '/quiet /norestart';                             Uninstall = '/uninstall /quiet /norestart' }
    'Squirrel'          = @{ Label = 'Squirrel (Electron)';    Install = '--silent';                                      Uninstall = '--uninstall -s' }
    'Omaha'             = @{ Label = 'Omaha / Google Update (Chrome, Brave, Edge)'; Install = '/silent /install';          Uninstall = '--force-uninstall' }
    'InstallAware'      = @{ Label = 'InstallAware';           Install = '/s';                                            Uninstall = '/s MODIFY=FALSE REMOVE=TRUE UNINSTALL=YES' }
    'AdvancedInstaller' = @{ Label = 'Advanced Installer';     Install = '/exenoui /qn';                                  Uninstall = '/x /qn' }
    'MsiWrapper'        = @{ Label = 'msiexec-style wrapper';  Install = '/qn /norestart';                                Uninstall = '/qn /norestart' }
    'Install4j'         = @{ Label = 'install4j';              Install = '-q -overwrite';                                 Uninstall = '-q' }
    'InstallBuilder'    = @{ Label = 'BitRock / InstallBuilder'; Install = '--mode unattended --unattendedmodeui none';   Uninstall = '--mode unattended' }
    'InstallAnywhere'   = @{ Label = 'InstallAnywhere';        Install = '-i silent';                                     Uninstall = '-i silent' }
    'QtIfw'             = @{ Label = 'Qt Installer Framework'; Install = 'install --accept-licenses --confirm-command --default-answer'; Uninstall = 'purge --confirm-command' }
    'Wise'              = @{ Label = 'Wise Installer';         Install = '/s';                                            Uninstall = '/s' }
    'SetupFactory'      = @{ Label = 'Setup Factory';          Install = '/S';                                            Uninstall = '/S' }
    'SevenZipSfx'       = @{ Label = '7-Zip self-extractor';   Install = '-y';                                            Uninstall = '' }
    'WinRarSfx'         = @{ Label = 'WinRAR self-extractor';  Install = '/S';                                            Uninstall = '' }
    'Unknown'           = @{ Label = 'Unknown / enter manually'; Install = '';                                            Uninstall = '' }
}

#region ---------------------------------------------------------------- Logging and helpers

function Write-PackagerLog
{
    param
    (
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.ToUpper().PadRight(5), $Message
    & $script:LogSink $line $Level
}

function ConvertTo-PsSingleQuoted
{
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    return "'" + $Text.Replace("'", "''") + "'"
}

function ConvertTo-PsExpandableString
{
    # Escapes only backtick and double quote so $env:... still expands in the generated script.
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    return $Text.Replace('`', '``').Replace('"', '`"')
}

function Get-DirFilesLiteral
{
    param([string]$Name)
    return '"$($adtSession.DirFiles)\' + (ConvertTo-PsExpandableString $Name) + '"'
}

function ConvertTo-IntArrayLiteral
{
    param($Values)
    $ints = @($Values | Where-Object { "$_" -match '^\s*-?\d+\s*$' } | ForEach-Object { [int]$_ })
    if ($ints.Count -eq 0) { return '@()' }
    return '@(' + ($ints -join ', ') + ')'
}

function ConvertTo-ProcessArrayLiteral
{
    # Accepts 'chrome', 'chrome.exe', or 'winword|Microsoft Word' (name|description).
    param($Values)
    $items = @()
    foreach ($v in @($Values | Where-Object { "$_".Trim() }))
    {
        $parts = "$v".Split('|', 2)
        $name  = $parts[0].Trim() -replace '\.exe$', ''
        if ($parts.Count -eq 2 -and $parts[1].Trim())
        {
            $items += '@{ Name = ' + (ConvertTo-PsSingleQuoted $name) + '; Description = ' + (ConvertTo-PsSingleQuoted $parts[1].Trim()) + ' }'
        }
        else
        {
            $items += ConvertTo-PsSingleQuoted $name
        }
    }
    if ($items.Count -eq 0) { return '@()' }
    return '@(' + ($items -join ', ') + ')'
}

function Format-UserCode
{
    # Indents a user-supplied code block; returns an array of lines (empty array when blank).
    param([string]$Code, [int]$Indent = 4)
    if ([string]::IsNullOrWhiteSpace($Code)) { return @() }
    $pad   = ' ' * $Indent
    $lines = ($Code -replace "`r`n", "`n").Split("`n")
    # Trim leading/trailing blank lines.
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[0]))                  { $lines = @($lines | Select-Object -Skip 1) }
    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1]))   { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
    return @($lines | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_)) { '' } else { $pad + $_.TrimEnd() } })
}

function Split-ListText
{
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-SafeName
{
    param([string]$Text)
    $s = ("$Text" -replace '[^\w\.\-]+', '_').Trim('_', '.')
    if (-not $s) { $s = 'Package' }
    return $s
}

function Get-PackageFolderName
{
    param($Def)
    $parts = @($Def.App.Vendor, $Def.App.Name, $Def.App.Version) | Where-Object { "$_".Trim() } | ForEach-Object { Get-SafeName $_ }
    return ($parts -join '_')
}

function Get-CleanVersion
{
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $m = [regex]::Match(($Text -replace ',', '.').Trim(), '\d+(\.\d+){0,3}')
    if ($m.Success) { return $m.Value }
    return $Text.Trim()
}

function Write-Utf8File
{
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

function Invoke-UiRefresh
{
    # Lets long-running work keep the window responsive. Replaced by the GUI's version when the window is open.
}

#endregion

#region ---------------------------------------------------------------- Definition model

function New-PackageDefinition
{
    return [pscustomobject]@{
        SchemaVersion = 1
        App = [pscustomobject]@{
            Vendor        = ''
            Name          = ''
            Version       = ''
            Arch          = ''
            Lang          = 'EN'
            Revision      = '01'
            ScriptVersion = '1.0.0'
            Author        = $env:USERNAME
        }
        Sources = [pscustomobject]@{
            Files        = @()
            SupportFiles = @()
        }
        Install = [pscustomobject]@{
            Type                 = 'MSI'
            File                 = ''
            Arguments            = ''
            Transforms           = @()
            ProductCode          = ''
            ProcessesToClose     = @()
            SuccessExitCodes     = @(0)
            RebootExitCodes      = @(1641, 3010)
            ShowWelcome          = $true
            AllowDefer           = $true
            DeferTimes           = 3
            ShowProgress         = $true
            ShowCompletionPrompt = $false
            PreScript            = ''
            CustomScript         = ''
            PostScript           = ''
        }
        Uninstall = [pscustomobject]@{
            Type            = 'MSI'
            ProductCode     = ''
            Name            = ''
            NameIsRegex     = $false
            ApplicationType = 'All'
            File            = ''
            Arguments       = ''
            SuccessExitCodes = @()   # empty = the Install tab's codes; some uninstallers report success as non-zero (Chromium: 19)
            PackageName     = ''
            PreScript       = ''
            CustomScript    = ''
            PostScript      = ''
        }
        Detection = [pscustomobject]@{
            Type             = 'MSI'
            ProductCode      = ''
            MinVersion       = ''
            DisplayName      = ''
            MatchMode        = 'Wildcard'
            FilePath         = ''
            CheckFileVersion = $true
            PackageName      = ''
            Script           = ''
        }
        Output = [pscustomobject]@{
            Destination     = ''
            DeployMode      = 'Silent'
            BuildIntuneWin  = $false
            IntuneWinAppUtil= ''
        }
        Intune = [pscustomobject]@{
            TenantId                = ''
            ClientId                = ''
            DisplayName             = ''   # blank = "<Name> <Version>"
            Description             = ''   # blank = auto
            Publisher               = ''   # blank = App.Vendor
            Developer               = ''
            Owner                   = ''
            Notes                   = ''
            InformationUrl          = ''
            PrivacyUrl              = ''
            InstallCommand          = ''   # blank = derived from Output.DeployMode
            UninstallCommand        = ''
            RunAsAccount            = 'system'
            RestartBehavior         = 'basedOnReturnCode'
            MaxRunTimeInMinutes     = 60
            MinimumOs               = 'v10_1809'
            Architecture            = ''   # blank = derived from App.Arch
            AllowAvailableUninstall = $true
            PublishAfterBuild       = $false
        }
    }
}

function Merge-PackageDefinition
{
    param($Base, $Overlay)
    if ($null -eq $Overlay) { return $Base }
    foreach ($p in $Base.PSObject.Properties)
    {
        $op = $Overlay.PSObject.Properties[$p.Name]
        if ($null -eq $op) { continue }
        if ($p.Value -is [pscustomobject] -and $op.Value -is [pscustomobject])
        {
            [void](Merge-PackageDefinition -Base $p.Value -Overlay $op.Value)
        }
        elseif ($p.Value -is [array])
        {
            $p.Value = @($op.Value | Where-Object { $null -ne $_ })
        }
        else
        {
            $p.Value = $op.Value
        }
    }
    return $Base
}

function Read-PackageDefinition
{
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Definition not found: $Path" }
    $json = [System.IO.File]::ReadAllText($Path)
    $loaded = $json | ConvertFrom-Json
    return Merge-PackageDefinition -Base (New-PackageDefinition) -Overlay $loaded
}

function Save-PackageDefinition
{
    param([Parameter(Mandatory)]$Def, [Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-Utf8File -Path $Path -Content ($Def | ConvertTo-Json -Depth 10)
}

function Test-PackageDefinition
{
    # Returns an array of problem strings (empty = valid).
    param($Def)
    $problems = @()
    if (-not "$($Def.App.Name)".Trim())    { $problems += 'Application name is required.' }
    if (-not "$($Def.App.Version)".Trim()) { $problems += 'Version is required.' }
    if (-not "$($Def.Output.Destination)".Trim()) { $problems += 'Destination folder is required.' }

    $i = $Def.Install
    if ($i.Type -in @('MSI', 'EXE', 'Script', 'MSIX') -and -not "$($i.File)".Trim())
    {
        $problems += "Install type '$($i.Type)' needs an installer file name (from the Files list)."
    }
    if ($i.Type -eq 'Custom' -and [string]::IsNullOrWhiteSpace($i.CustomScript))
    {
        $problems += 'Custom install type needs a custom install script.'
    }
    if ($i.Type -eq 'MSI' -and "$($i.File)" -notmatch '\.msi$')
    {
        $problems += 'Install type MSI but the installer file is not an .msi.'
    }

    $u = $Def.Uninstall
    switch ($u.Type)
    {
        'MSI'    { if (-not "$($u.ProductCode)".Trim() -and -not "$($i.ProductCode)".Trim() -and "$($i.File)" -notmatch '\.msi$') { $problems += 'MSI uninstall needs a product code (or an MSI installer file).' } }
        'Name'   { if (-not "$($u.Name)".Trim()) { $problems += 'Uninstall by name needs the installed application name.' } }
        'EXE'    { if (-not "$($u.File)".Trim()) { $problems += 'EXE uninstall needs the uninstaller path on the device.' } }
        'Script' { if (-not "$($u.File)".Trim()) { $problems += 'Script uninstall needs a script file name (.ps1, .cmd, .bat or .vbs) from the Files list.' } }
        'MSIX'   { if (-not "$($u.PackageName)".Trim()) { $problems += 'MSIX uninstall needs the package identity name.' } }
        'Custom' { if ([string]::IsNullOrWhiteSpace($u.CustomScript)) { $problems += 'Custom uninstall type needs a custom uninstall script.' } }
    }

    $d = $Def.Detection
    switch ($d.Type)
    {
        'MSI'      { if (-not "$($d.ProductCode)".Trim() -and -not "$($i.ProductCode)".Trim()) { $problems += 'MSI detection needs a product code.' } }
        'Registry' { if (-not "$($d.DisplayName)".Trim()) { $problems += 'Registry detection needs a DisplayName.' } }
        'File'     { if (-not "$($d.FilePath)".Trim()) { $problems += 'File detection needs a file path.' } }
        'MSIX'     { if (-not "$($d.PackageName)".Trim()) { $problems += 'MSIX detection needs the package identity name.' } }
        'Script'   { if ([string]::IsNullOrWhiteSpace($d.Script)) { $problems += 'Custom detection needs a script.' } }
    }

    foreach ($src in @($Def.Sources.Files) + @($Def.Sources.SupportFiles))
    {
        $probe = if ("$src".EndsWith('\*')) { "$src".Substring(0, "$src".Length - 2) } else { "$src" }
        if (-not (Test-Path -LiteralPath $probe)) { $problems += "Source not found: $src" }
    }
    return ,@($problems)
}

#endregion

#region ---------------------------------------------------------------- Installer inspection

function Get-MsiProperties
{
    param([Parameter(Mandatory)][string]$Path)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $props = @{}
    try
    {
        $db   = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('SELECT Property, Value FROM Property'))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        while ($true)
        {
            $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($null -eq $rec) { break }
            $k = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))
            $v = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(2))
            $props[$k] = $v
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($rec)
        }
        [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($view)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db)
    }
    finally
    {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
    }
    return $props
}

function Get-InstallerEngine
{
    param([Parameter(Mandatory)][string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try
    {
        $len = [int][Math]::Min($fs.Length, 8MB)
        $buf = New-Object byte[] $len
        [void]$fs.Read($buf, 0, $len)
        # The end of the file too: Omaha writes its tag into the signature block of even a 150 MB standalone installer.
        $tailLen = [int][Math]::Min([Math]::Max(0, $fs.Length - $len), 256KB)
        $tail = New-Object byte[] $tailLen
        if ($tailLen -gt 0) { $fs.Position = $fs.Length - $tailLen; [void]$fs.Read($tail, 0, $tailLen) }
    }
    finally { $fs.Dispose() }
    $latin = [System.Text.Encoding]::GetEncoding(28591).GetString($buf)
    $wide  = $latin -replace "`0", ''
    $end   = [System.Text.Encoding]::GetEncoding(28591).GetString($tail)
    $vi    = (Get-Item -LiteralPath $Path).VersionInfo
    $meta  = "$($vi.FileDescription) $($vi.ProductName) $($vi.Comments) $($vi.InternalName) $($vi.OriginalFilename)"

    # Omaha (Google Update) metainstallers - Chrome, Brave, Edge - before anything else: they carry other engines' strings.
    if ("$latin$end" -match 'Gact2\.0Omaha|appguid=\{' -or "$($vi.FileDescription)" -match '(?i)\bUpdate Setup$') { return 'Omaha' }
    if ($latin -match 'Inno Setup' -or $wide -match 'Inno Setup')                                   { return 'Inno' }
    if ($latin -match 'Squirrel' -or $wide -match 'Squirrel')                                       { return 'Squirrel' }
    if ($latin -match 'Nullsoft' -or $latin -match 'NSIS Error' -or $wide -match 'Nullsoft')        { return 'NSIS' }
    if ($meta -match 'InstallShield' -or $latin -match 'InstallShield' -or $wide -match 'InstallShield') { return 'InstallShield' }
    if ($latin -match '\.wixburn' -or $meta -match 'WiX')                                           { return 'WiX' }
    if ($latin -match 'InstallAware' -or $wide -match 'InstallAware')                               { return 'InstallAware' }
    if ($latin -match 'Advanced Installer' -or $wide -match 'Advanced Installer' -or $meta -match 'Advanced Installer') { return 'AdvancedInstaller' }
    if ($latin -match 'MSI Wrapper' -or $wide -match 'MSI Wrapper' -or $wide -match 'msiexec')      { return 'MsiWrapper' }
    if ($latin -match 'install4j' -or $wide -match 'install4j' -or $meta -match 'install4j')         { return 'Install4j' }
    if ($latin -match 'BitRock' -or $wide -match 'BitRock' -or $latin -match 'InstallBuilder' -or $wide -match 'InstallBuilder') { return 'InstallBuilder' }
    if ($latin -match 'InstallAnywhere' -or $wide -match 'InstallAnywhere')                         { return 'InstallAnywhere' }
    if ($latin -match 'Qt Installer Framework' -or $wide -match 'Qt Installer Framework' -or $latin -match 'QtInstallerFramework') { return 'QtIfw' }
    if ($latin -match 'Wise Installation' -or $wide -match 'Wise Installation' -or $meta -match 'Wise') { return 'Wise' }
    if ($latin -match 'Setup Factory' -or $wide -match 'Setup Factory' -or $meta -match 'Setup Factory') { return 'SetupFactory' }
    if ($latin -match '!@Install@!' -or $latin -match '7-Zip SFX' -or $wide -match '7-Zip SFX' -or $meta -match '7-Zip')    { return 'SevenZipSfx' }
    if ($latin -match 'WinRAR SFX' -or $wide -match 'WinRAR SFX' -or $meta -match 'WinRAR')          { return 'WinRarSfx' }
    return 'Unknown'
}

function Find-InstallerSwitchStrings
{
    # Which known silent switches appear verbatim inside the binary (ANSI or UTF-16). Evidence for ranking, not proof.
    param([Parameter(Mandatory)][string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try
    {
        $len = [int][Math]::Min($fs.Length, 8MB)
        $buf = New-Object byte[] $len
        [void]$fs.Read($buf, 0, $len)
    }
    finally { $fs.Dispose() }
    # ANSI view plus UTF-16 at both byte alignments; nulls stay in place so adjacent strings don't merge.
    $views = @(
        [System.Text.Encoding]::GetEncoding(28591).GetString($buf),
        [System.Text.Encoding]::Unicode.GetString($buf),
        [System.Text.Encoding]::Unicode.GetString($buf, 1, $len - 1)
    )
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($tok in $script:SwitchVocabulary)
    {
        # ASCII-only boundaries: .NET's \w matches Unicode letters, which random UTF-16 code units often are.
        $pattern = '(?<![A-Za-z0-9_/\-])' + [regex]::Escape($tok) + '(?![A-Za-z0-9_\-])'
        foreach ($v in $views) { if ($v -cmatch $pattern) { $found.Add($tok); break } }
    }
    return $found.ToArray()
}

function Get-SilentCandidates
{
    # Ordered, case-sensitive-unique list of argument strings to try for an EXE.
    param([Parameter(Mandatory)][string]$Path, [string]$Engine, [string]$CurrentArgs, [int]$Max = 4)
    $list = New-Object System.Collections.Generic.List[string]
    $add  = New-Object System.Collections.Generic.List[string]
    if ("$CurrentArgs".Trim()) { $add.Add("$CurrentArgs".Trim()) }
    if ($Engine -and $script:SilentPresets.Contains($Engine) -and $script:SilentPresets[$Engine].Install) { $add.Add($script:SilentPresets[$Engine].Install) }
    $strings = @(Find-InstallerSwitchStrings -Path $Path)
    foreach ($c in $script:GenericSilentCandidates)
    {
        $first = ($c -split '\s+')[0]
        if ($strings -ccontains $first) { $add.Add($c) }
    }
    foreach ($c in $script:GenericSilentCandidates) { $add.Add($c) }
    foreach ($c in $add) { if (-not $list.Contains($c)) { $list.Add($c) } }
    if ($list.Count -gt $Max) { $list.RemoveRange($Max, $list.Count - $Max) }
    return $list.ToArray()
}

function Get-AppxManifestInfo
{
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try
    {
        $entry = $zip.GetEntry('AppxManifest.xml')
        if (-not $entry) { $entry = $zip.GetEntry('AppxMetadata/AppxBundleManifest.xml') }
        if (-not $entry) { throw 'No AppxManifest.xml or AppxBundleManifest.xml found in the package.' }
        $sr = New-Object System.IO.StreamReader($entry.Open())
        try { [xml]$m = $sr.ReadToEnd() } finally { $sr.Dispose() }
        $identity = $m.DocumentElement.Identity
        $props    = $m.DocumentElement.Properties
        $display  = ''
        $vendor   = ''
        if ($props)
        {
            $display = "$($props.DisplayName)"
            $vendor  = "$($props.PublisherDisplayName)"
        }
        if (-not $display -or $display -like 'ms-resource:*') { $display = "$($identity.Name)" }
        if (-not $vendor -or $vendor -like 'ms-resource:*')
        {
            $pub = "$($identity.Publisher)"
            if ($pub -match '(?:^|,)\s*CN=([^,]+)') { $vendor = $Matches[1].Trim() } else { $vendor = $pub }
        }
        $arch = "$($identity.ProcessorArchitecture)"
        return [pscustomobject]@{
            PackageName = "$($identity.Name)"
            Version     = "$($identity.Version)"
            Publisher   = "$($identity.Publisher)"
            DisplayName = $display
            Vendor      = $vendor
            Arch        = $(switch ($arch) { 'x64' { 'x64' } 'x86' { 'x86' } 'arm64' { 'ARM64' } default { '' } })
        }
    }
    finally { $zip.Dispose() }
}

function Get-MsiTemplate
{
    # Summary information Template (PID 7): "x64;1033", "Intel;1033", "Arm64;1033".
    param([Parameter(Mandatory)][string]$Path)
    $installer = New-Object -ComObject WindowsInstaller.Installer
    try
    {
        $si = $installer.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $installer, @($Path, 0))
        $t  = $si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(7))
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($si)
        return "$t"
    }
    catch { return '' }
    finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
}

function Get-PeMachine
{
    # x64 / x86 / ARM64 from the PE header. Bootstrappers are often x86 even when they install x64 software.
    param([Parameter(Mandatory)][string]$Path)
    try
    {
        $fs = [System.IO.File]::OpenRead($Path)
        try
        {
            $br = New-Object System.IO.BinaryReader($fs)
            if ($br.ReadUInt16() -ne 0x5A4D) { return '' }
            $fs.Position = 0x3C
            $fs.Position = $br.ReadInt32()
            if ($br.ReadUInt32() -ne 0x00004550) { return '' }
            switch ([int]$br.ReadUInt16())
            {
                0x8664  { return 'x64' }
                0x014C  { return 'x86' }
                0xAA64  { return 'ARM64' }
                default { return '' }
            }
        }
        finally { $fs.Dispose() }
    }
    catch { return '' }
}

function Get-ArchFromText
{
    # Architecture named in a file or product name ("npp.8.9.Installer.x64.exe", "7-Zip 26.04 (x64 edition)").
    param([string]$Text)
    $t = " $Text ".ToLowerInvariant()
    if ($t -match '[^a-z0-9](arm64|aarch64)[^a-z0-9]')                { return 'ARM64' }
    if ($t -match '[^a-z0-9](x64|amd64|win64|x86[-_]64|64-?bit)[^a-z0-9]') { return 'x64' }
    if ($t -match '[^a-z0-9](x86|win32|i386|i686|32-?bit)[^a-z0-9]')   { return 'x86' }
    return ''
}

function Get-CleanAppName
{
    # "7-Zip 26.04 (x64 edition)" -> "7-Zip"; "Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.44.35211" ->
    # "Microsoft Visual C++ 2015-2022 Redistributable"; "Notepad++ (64-bit x64)" -> "Notepad++".
    param([string]$Name, [string]$Version)
    $n = ("$Name" -replace '[\u00AE\u2122\u00A9]|\((R|TM|C)\)', '').Trim()
    if (-not $n) { return '' }
    $original = $n
    if ($Version) { $n = $n.Replace($Version, ' ') }
    $n = $n -replace '(?<![\w.])v?\d+(?:\.\d+){1,3}(?![\w.])', ' '
    $n = $n -replace '(?i)[\(\[]\s*(x64|x86|amd64|arm64|win64|64-bit|32-bit)(\s+edition)?\s*[\)\]]', ' '
    $n = $n -replace '(?i)(?<![\w-])(x64|x86|amd64|arm64|win64|64-bit|32-bit)(?![\w-])', ' '
    $n = $n -replace '\(\s*\)|\[\s*\]', ' '
    $n = ($n -replace '\s{2,}', ' ').Trim([char[]]@(' ', '-', '_', ',', ':'))
    if (-not $n) { return $original }
    return $n
}

function Get-CleanVendor
{
    # Drops e-mail addresses and URLs (Notepad++: "Don HO don.h@free.fr", WinMerge: "https://winmerge.org"); falls back
    # to the organisation in the Authenticode signature.
    param([string]$Text, [string]$Path)
    $v = ("$Text" -replace '<?[\w.+-]+@[\w-]+(\.[\w-]+)+>?', '') -replace '\s{2,}', ' '
    $v = $v.Trim([char[]]@(' ', ',', '-', '(', ')'))
    if ($v -match '^(?i)(https?://|www\.)') { $v = '' }
    if (-not $v -and $Path)
    {
        try
        {
            $subject = "$((Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).SignerCertificate.Subject)"
            if ($subject -match '(?:^|,\s*)O="?([^",]+)')      { $v = $Matches[1].Trim() }
            elseif ($subject -match '(?:^|,\s*)CN="?([^",]+)') { $v = $Matches[1].Trim() }
        }
        catch { }
    }
    return $v
}

function Get-FileVersionText
{
    # Product version from a version resource. The text and the numeric fields can disagree (Notepad++ 8.9.8.1 says
    # "8.981" as text); the numeric fields win when they do.
    param($VersionInfo)
    if (-not $VersionInfo) { return '' }
    $text = Get-CleanVersion "$($VersionInfo.ProductVersion)"
    $num  = '{0}.{1}.{2}.{3}' -f $VersionInfo.ProductMajorPart, $VersionInfo.ProductMinorPart, $VersionInfo.ProductBuildPart, $VersionInfo.ProductPrivatePart
    if ($num -eq '0.0.0.0') { $num = '{0}.{1}.{2}.{3}' -f $VersionInfo.FileMajorPart, $VersionInfo.FileMinorPart, $VersionInfo.FileBuildPart, $VersionInfo.FilePrivatePart }
    if ($num -eq '0.0.0.0') { $num = '' }
    if (-not $text) { if ($num) { return $num }; return (Get-CleanVersion "$($VersionInfo.FileVersion)") }
    if (-not $num) { return $text }
    $pad = { param($v) $p = @($v.Split('.') | ForEach-Object { [int64]$_ }); while ($p.Count -lt 4) { $p += 0 }; ($p[0..3] -join '.') }
    if ((& $pad $text) -eq (& $pad $num)) { return $text }
    return $num
}

function Split-NameAndVersion
{
    # "Contoso Agent 2.1.0" / "contoso_agent_v2.1" / "npp.8.9.8.1.Installer.x64" -> name and version (either may be blank).
    param([string]$Text)
    $t = "$Text".Trim()
    $m = [regex]::Match($t, '^(?<name>.*?)[\s_\-\.]*v?(?<ver>\d+(?:[\._]\d+){1,3})(?=$|[\s_\-\.])')
    if ($m.Success -and $m.Groups['name'].Value.Trim([char[]]@(' ', '-', '_', '.')))
    {
        return @{ Name = ($m.Groups['name'].Value -replace '_', ' ').Trim([char[]]@(' ', '-', '.')); Version = ($m.Groups['ver'].Value -replace '_', '.') }
    }
    return @{ Name = ($t -replace '_', ' ').Trim(); Version = '' }
}

function Get-InstallerInfo
{
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Installer not found: $Path" }
    $ext  = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $info = [pscustomobject]@{
        Path          = $Path
        FileName      = [System.IO.Path]::GetFileName($Path)
        Type          = ''
        Vendor        = ''
        Name          = ''
        RawName       = ''
        Version       = ''
        ProductCode   = ''
        Engine        = ''
        InstallArgs   = ''
        UninstallArgs = ''
        PackageName   = ''
        Arch          = ''
    }
    switch ($ext)
    {
        '.msi'
        {
            $p = Get-MsiProperties -Path $Path
            $info.Type        = 'MSI'
            $info.Vendor      = Get-CleanVendor -Text "$($p['Manufacturer'])"
            $info.RawName     = "$($p['ProductName'])".Trim()
            $info.Version     = Get-CleanVersion "$($p['ProductVersion'])"
            $info.Name        = Get-CleanAppName -Name $info.RawName -Version $info.Version
            $info.ProductCode = "$($p['ProductCode'])".Trim()
            $info.Engine      = 'MSI'
            $template = Get-MsiTemplate -Path $Path
            $info.Arch = switch -Regex ($template) { '^(?i)x64' { 'x64' } '^(?i)arm64' { 'ARM64' } '^(?i)intel;' { 'x86' } default { '' } }
            if (-not $info.Arch) { $info.Arch = Get-ArchFromText "$($info.FileName) $($info.RawName)" }
        }
        '.exe'
        {
            $vi = (Get-Item -LiteralPath $Path).VersionInfo
            $info.Type    = 'EXE'
            $info.Vendor  = Get-CleanVendor -Text "$($vi.CompanyName)" -Path $Path
            $info.RawName = "$($vi.ProductName)".Trim()
            if (-not $info.RawName) { $info.RawName = "$($vi.FileDescription)".Trim() }
            $info.Version = Get-FileVersionText $vi
            $info.Name    = Get-CleanAppName -Name $info.RawName -Version $info.Version
            if (-not $info.Name -or $info.Name -match '^(?i)(setup|install|installer)$')
            {
                $split = Split-NameAndVersion ([System.IO.Path]::GetFileNameWithoutExtension($Path))
                $info.Name = Get-CleanAppName -Name $split.Name
                if (-not $info.Version) { $info.Version = $split.Version }
            }
            $info.Engine  = Get-InstallerEngine -Path $Path
            $preset = $script:SilentPresets[$info.Engine]
            if ($preset)
            {
                $info.InstallArgs   = $preset.Install
                $info.UninstallArgs = $preset.Uninstall
            }
            $info.Arch = Get-ArchFromText "$($info.FileName) $($info.RawName)"
            if (-not $info.Arch) { $pe = Get-PeMachine -Path $Path; if ($pe -ne 'x86') { $info.Arch = $pe } }
        }
        { $_ -in @('.msix', '.appx', '.msixbundle', '.appxbundle') }
        {
            $m = Get-AppxManifestInfo -Path $Path
            $info.Type        = 'MSIX'
            $info.Vendor      = $m.Vendor
            $info.Name        = $m.DisplayName
            $info.RawName     = $m.DisplayName
            $info.Version     = $m.Version
            $info.PackageName = $m.PackageName
            $info.Engine      = 'MSIX'
            $info.Arch        = $m.Arch
        }
        { $_ -in @('.ps1', '.cmd', '.bat', '.vbs') }
        {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            if ($base -match '^(install|setup|deploy|run|main|start|silent|default|go)([-_ ]?(app|all|script|me|silent|x64|x86))?$')
            {
                $base = Split-Path -Path (Split-Path -Path $Path -Parent) -Leaf
            }
            $split = Split-NameAndVersion $base
            $info.Type    = 'Script'
            $info.Name    = $split.Name
            $info.RawName = $base
            $info.Version = $split.Version
            $info.Engine  = 'Script'
        }
        default { throw "Unsupported installer type '$ext'. Supported: .msi, .exe, .msix, .appx, .msixbundle, .appxbundle, .ps1, .cmd, .bat, .vbs" }
    }
    return $info
}

function Set-DefinitionFromInstaller
{
    # Applies installer metadata to a definition (App, Install, Uninstall, Detection) and adds the file to Sources.
    param([Parameter(Mandatory)]$Def, [Parameter(Mandatory)]$Info)
    if ($Info.Vendor)  { $Def.App.Vendor  = $Info.Vendor }
    if ($Info.Name)    { $Def.App.Name    = $Info.Name }
    if ($Info.Version) { $Def.App.Version = $Info.Version }
    if ($Info.PSObject.Properties['Arch'] -and $Info.Arch) { $Def.App.Arch = $Info.Arch }

    if (@($Def.Sources.Files) -notcontains $Info.Path) { $Def.Sources.Files = @($Def.Sources.Files) + @($Info.Path) }

    $Def.Install.Type = $Info.Type
    $Def.Install.File = $Info.FileName
    switch ($Info.Type)
    {
        'MSI'
        {
            $Def.Install.ProductCode   = $Info.ProductCode
            $Def.Install.Arguments     = ''
            $Def.Uninstall.Type        = 'MSI'
            $Def.Uninstall.ProductCode = $Info.ProductCode
            $Def.Detection.Type        = 'MSI'
            $Def.Detection.ProductCode = $Info.ProductCode
            $Def.Detection.MinVersion  = $Info.Version
        }
        'EXE'
        {
            $Def.Install.Arguments         = $Info.InstallArgs
            $Def.Uninstall.Type            = 'Name'
            $Def.Uninstall.Name            = $Info.Name + '*'
            $Def.Uninstall.NameIsRegex     = $false
            $Def.Uninstall.ApplicationType = 'All'
            $Def.Uninstall.Arguments       = $Info.UninstallArgs
            $Def.Detection.Type            = 'Registry'
            $Def.Detection.DisplayName     = $Info.Name + '*'
            $Def.Detection.MatchMode       = 'Wildcard'
            $Def.Detection.MinVersion      = $Info.Version
        }
        'MSIX'
        {
            $Def.Uninstall.Type        = 'MSIX'
            $Def.Uninstall.PackageName = $Info.PackageName
            $Def.Detection.Type        = 'MSIX'
            $Def.Detection.PackageName = $Info.PackageName
            $Def.Detection.MinVersion  = $Info.Version
        }
        'Script'
        {
            $Def.Uninstall.Type = 'Custom'
            $Def.Detection.Type = 'Script'
        }
    }
    return $Def
}

#endregion

#region ---------------------------------------------------------------- Code generation: Invoke-AppDeployToolkit.ps1

function New-WelcomeBlock
{
    param($Install)
    $L = New-Object System.Collections.Generic.List[string]
    $deferText = if ($Install.AllowDefer) { ", allow up to $([int]$Install.DeferTimes) deferrals" } else { '' }
    $L.Add("    ## Show Welcome Message, close processes if specified$deferText, verify there is enough disk space to complete the install, and persist the prompt.")
    $L.Add('    $saiwParams = @{')
    if ($Install.AllowDefer)
    {
        $L.Add('        AllowDefer = $true')
        $L.Add("        DeferTimes = $([int]$Install.DeferTimes)")
    }
    $L.Add('        CheckDiskSpace = $true')
    $L.Add('        PersistPrompt = $true')
    $L.Add('    }')
    $L.Add('    if ($adtSession.AppProcessesToClose.Count -gt 0)')
    $L.Add('    {')
    $L.Add('        $saiwParams.Add(''CloseProcesses'', $adtSession.AppProcessesToClose)')
    $L.Add('    }')
    $L.Add('    Show-ADTInstallationWelcome @saiwParams')
    $L.Add('')
    return $L
}

function New-ScriptCallCode
{
    # Runs a script from Files\ the right way for its type, from the script's own folder. .ps1 runs in-process (every
    # PSADT function and $adtSession are available) and a failing exit code fails the deployment; .cmd / .bat / .vbs go
    # through cmd.exe / cscript.exe with Start-ADTProcess, which applies the success and reboot exit codes.
    param([Parameter(Mandatory)][string]$File, [string]$Arguments)
    $file = $File.Trim()
    $leaf = Split-Path -Path $file -Leaf
    $argText = "$Arguments".Trim()
    $L = New-Object System.Collections.Generic.List[string]
    switch ([System.IO.Path]::GetExtension($file).ToLowerInvariant())
    {
        { $_ -in @('.cmd', '.bat') }
        {
            $L.Add('$scriptFile = ' + (Get-DirFilesLiteral $file))
            $L.Add('Start-ADTProcess -FilePath "$env:ComSpec" -ArgumentList (''/c ""{0}"{1}"'' -f $scriptFile, ' + (ConvertTo-PsSingleQuoted $(if ($argText) { " $argText" } else { '' })) + ') -WorkingDirectory (Split-Path -Path $scriptFile -Parent) -WindowStyle Hidden')
        }
        '.vbs'
        {
            $L.Add('$scriptFile = ' + (Get-DirFilesLiteral $file))
            $L.Add('Start-ADTProcess -FilePath "$env:SystemRoot\System32\cscript.exe" -ArgumentList (''//nologo //B "{0}"{1}'' -f $scriptFile, ' + (ConvertTo-PsSingleQuoted $(if ($argText) { " $argText" } else { '' })) + ') -WorkingDirectory (Split-Path -Path $scriptFile -Parent) -WindowStyle Hidden')
        }
        default
        {
            $L.Add('## Runs in-process, so the script can use every PSADT function and $adtSession.')
            $L.Add('$scriptFile = ' + (Get-DirFilesLiteral $file))
            $L.Add('Push-Location -LiteralPath (Split-Path -Path $scriptFile -Parent)')
            $L.Add('try')
            $L.Add('{')
            $L.Add('    $global:LASTEXITCODE = 0')
            $L.Add('    & $scriptFile' + $(if ($argText) { " $argText" } else { '' }))
            $L.Add('    if ($LASTEXITCODE -and $adtSession.AppSuccessExitCodes -notcontains $LASTEXITCODE -and $adtSession.AppRebootExitCodes -notcontains $LASTEXITCODE)')
            $L.Add('    {')
            $L.Add('        throw "' + (ConvertTo-PsExpandableString $leaf) + ' exited with code $LASTEXITCODE."')
            $L.Add('    }')
            $L.Add('}')
            $L.Add('finally')
            $L.Add('{')
            $L.Add('    Pop-Location')
            $L.Add('}')
        }
    }
    return $L
}

function New-InstallActionCode
{
    param($Def, [ValidateSet('Install', 'Repair')][string]$Action = 'Install')
    $i = $Def.Install
    $L = New-Object System.Collections.Generic.List[string]
    switch ($i.Type)
    {
        'MSI'
        {
            if ($Action -eq 'Repair')
            {
                $L.Add('    ## Repair the MSI (msiexec /f). Toolkit supplies silent switches and logging.')
                $L.Add('    Start-ADTMsiProcess -Action Repair -FilePath ' + (Get-DirFilesLiteral $i.File))
            }
            else
            {
                $L.Add('    ## Install the MSI. The toolkit supplies the silent switches and logging; extra properties are appended.')
                $L.Add('    $msiParams = @{')
                $L.Add("        Action = 'Install'")
                $L.Add('        FilePath = ' + (Get-DirFilesLiteral $i.File))
                $tr = @($i.Transforms | Where-Object { "$_".Trim() })
                if ($tr.Count -gt 0)
                {
                    $L.Add('        Transforms = @(' + (($tr | ForEach-Object { Get-DirFilesLiteral $_.Trim() }) -join ', ') + ')')
                }
                if ("$($i.Arguments)".Trim())
                {
                    $L.Add('        AdditionalArgumentList = ' + (ConvertTo-PsSingleQuoted $i.Arguments.Trim()))
                }
                $L.Add('    }')
                $L.Add('    Start-ADTMsiProcess @msiParams')
            }
        }
        'EXE'
        {
            if ($Action -eq 'Repair') { $L.Add('    ## Repair by re-running the installer.') }
            $line = '    Start-ADTProcess -FilePath ' + (Get-DirFilesLiteral $i.File)
            if ("$($i.Arguments)".Trim()) { $line += ' -ArgumentList ' + (ConvertTo-PsSingleQuoted $i.Arguments.Trim()) }
            $line += ' -WindowStyle Hidden'
            $L.Add($line)
        }
        'Script'
        {
            if ($Action -eq 'Repair') { $L.Add('    ## Repair by re-running the install script.') }
            foreach ($ln in (New-ScriptCallCode -File $i.File -Arguments $i.Arguments)) { $L.Add('    ' + $ln) }
        }
        'MSIX'
        {
            if ($Action -eq 'Repair') { $L.Add('    ## Repair by re-provisioning the package.') }
            $L.Add('    ## Provision for all users (also installs for the current user on next sign-in).')
            $line = '    Add-AppxProvisionedPackage -Online -PackagePath ' + (Get-DirFilesLiteral $i.File) + ' -SkipLicense'
            if ("$($i.Arguments)".Trim()) { $line += ' ' + $i.Arguments.Trim() }
            $L.Add($line + ' | Out-Null')
        }
        'Custom'
        {
            if ($Action -eq 'Repair') { $L.Add('    ## Repair re-runs the custom install logic.') }
            foreach ($ln in (Format-UserCode -Code $i.CustomScript)) { $L.Add($ln) }
        }
    }
    return $L
}

function New-UninstallActionCode
{
    param($Def)
    $u = $Def.Uninstall
    $i = $Def.Install
    $L = New-Object System.Collections.Generic.List[string]
    # Extra exit codes that mean the uninstall worked (Chromium's setup.exe: 19) are ignored, not added as success codes:
    # the toolkit exits with the last success code it saw, and Intune would report an uninstall that exits 19 as failed.
    $successParam = ''
    $known = @(@($i.SuccessExitCodes) + @($i.RebootExitCodes) | Where-Object { "$_" -match '^\s*-?\d+\s*$' } | ForEach-Object { [int]$_ })
    $extraCodes = @($u.SuccessExitCodes | Where-Object { "$_" -match '^\s*-?\d+\s*$' } | ForEach-Object { [int]$_ } | Where-Object { $known -notcontains $_ } | Select-Object -Unique)
    if ($extraCodes.Count -gt 0) { $successParam = ' -IgnoreExitCodes ' + (ConvertTo-IntArrayLiteral $extraCodes) }
    switch ($u.Type)
    {
        'MSI'
        {
            $code = "$($u.ProductCode)".Trim()
            if (-not $code) { $code = "$($i.ProductCode)".Trim() }
            $L.Add('    $msiParams = @{')
            $L.Add("        Action = 'Uninstall'")
            if ($code) { $L.Add('        ProductCode = ' + (ConvertTo-PsSingleQuoted $code)) }
            else       { $L.Add('        FilePath = ' + (Get-DirFilesLiteral $i.File)) }
            if ("$($u.Arguments)".Trim()) { $L.Add('        AdditionalArgumentList = ' + (ConvertTo-PsSingleQuoted $u.Arguments.Trim())) }
            $L.Add('    }')
            $L.Add('    Start-ADTMsiProcess @msiParams')
        }
        'Name'
        {
            # The toolkit's own default (Contains) would also remove every other app whose name merely contains this one.
            $n = $u.Name.Trim()
            $match = if ($u.NameIsRegex) { 'Regex' } elseif ($n -match '[\*\?]') { 'Wildcard' } else { 'Exact' }
            $search = '-Name ' + (ConvertTo-PsSingleQuoted $n) + " -NameMatch $match"
            if ($u.ApplicationType -eq 'EXE')
            {
                # Not Uninstall-ADTApplication: it runs the uninstaller from the uninstaller's own folder, and uninstallers
                # that delete that folder (Chromium's setup.exe) then fail even though the app is gone.
                $L.Add('    ## Runs the uninstall command the app registered (the quiet one if there is one), from the Windows folder.')
                $L.Add("    `$apps = Get-ADTApplication $search -ApplicationType EXE")
                $L.Add('    foreach ($app in $apps)')
                $L.Add('    {')
                $L.Add('        $sapParams = @{ FilePath = $app.UninstallStringFilePath; WorkingDirectory = $env:SystemRoot; WindowStyle = ''Hidden'' }')
                if ("$($u.Arguments)".Trim())
                {
                    $L.Add('        if ($app.QuietUninstallStringFilePath) { $sapParams.FilePath = $app.QuietUninstallStringFilePath }')
                    $L.Add('        $sapParams.ArgumentList = ' + (ConvertTo-PsSingleQuoted $u.Arguments.Trim()))
                }
                else
                {
                    $L.Add('        $argv = $app.UninstallStringArgumentList')
                    $L.Add('        if ($app.QuietUninstallStringFilePath) { $sapParams.FilePath = $app.QuietUninstallStringFilePath; $argv = $app.QuietUninstallStringArgumentList }')
                    $L.Add('        if ($argv) { $sapParams.ArgumentList = $argv }')
                }
                $L.Add('        Write-ADTLogEntry -Message "Uninstalling [$($app.DisplayName) $($app.DisplayVersion)]."')
                $L.Add('        Start-ADTProcess @sapParams' + $successParam)
                $L.Add('    }')
                $L.Add('    if (-not $apps) { Write-ADTLogEntry -Message ''No installed application matches [' + ($n -replace "'", "''") + ']; nothing to remove.'' -Severity 2 }')
            }
            else
            {
                $line = "    Uninstall-ADTApplication $search"
                if ($u.ApplicationType -and $u.ApplicationType -ne 'All') { $line += " -ApplicationType $($u.ApplicationType)" }
                if ("$($u.Arguments)".Trim())
                {
                    $L.Add('    ## ArgumentList is used for EXE uninstallers (replaces the arguments in UninstallString); MSI entries get the toolkit defaults.')
                    $line += ' -ArgumentList ' + (ConvertTo-PsSingleQuoted $u.Arguments.Trim())
                }
                $L.Add($line + $successParam)
            }
        }
        'EXE'
        {
            $L.Add('    ## Uninstaller path on the device ($env: variables expand at run time).')
            $L.Add('    $uninstaller = "' + (ConvertTo-PsExpandableString $u.File.Trim()) + '"')
            $L.Add('    if (Test-Path -LiteralPath $uninstaller -PathType Leaf)')
            $L.Add('    {')
            $line = '        Start-ADTProcess -FilePath $uninstaller'
            if ("$($u.Arguments)".Trim()) { $line += ' -ArgumentList ' + (ConvertTo-PsSingleQuoted $u.Arguments.Trim()) }
            $line += ' -WindowStyle Hidden' + $successParam
            $L.Add($line)
            $L.Add('    }')
            $L.Add('    else')
            $L.Add('    {')
            $L.Add('        Write-ADTLogEntry -Message "Uninstaller not found at [$uninstaller]; nothing to remove." -Severity 2')
            $L.Add('    }')
        }
        'Script'
        {
            foreach ($ln in (New-ScriptCallCode -File $u.File -Arguments $u.Arguments)) { $L.Add('    ' + $ln) }
        }
        'MSIX'
        {
            $pn = ConvertTo-PsSingleQuoted $u.PackageName.Trim()
            $L.Add("    `$packageName = $pn")
            $L.Add('    Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $packageName } | ForEach-Object {')
            $L.Add('        Write-ADTLogEntry -Message "Removing provisioned package [$($_.PackageName)]."')
            $L.Add('        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -AllUsers | Out-Null')
            $L.Add('    }')
            $L.Add('    Get-AppxPackage -AllUsers -Name $packageName -ErrorAction SilentlyContinue | ForEach-Object {')
            $L.Add('        Write-ADTLogEntry -Message "Removing installed package [$($_.PackageFullName)] for all users."')
            $L.Add('        Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue')
            $L.Add('    }')
        }
        'Custom'
        {
            foreach ($ln in (Format-UserCode -Code $u.CustomScript)) { $L.Add($ln) }
        }
        'None'
        {
            $L.Add('    ## No uninstall action defined for this package.')
            $L.Add('    Write-ADTLogEntry -Message ''No uninstall action is defined for this package.'' -Severity 2')
        }
    }
    return $L
}

function New-DeploymentSections
{
    # Generates the "Variables" and "Functions" sections of Invoke-AppDeployToolkit.ps1.
    param([Parameter(Mandatory)]$Def, [string]$ToolkitVersion = '4.1.8')
    $a = $Def.App
    $i = $Def.Install
    $L = New-Object System.Collections.Generic.List[string]
    $sep = '##================================================'

    $L.Add($sep); $L.Add('## MARK: Variables'); $L.Add($sep); $L.Add('')
    $L.Add("# Generated by PSADT Packager $script:PackagerVersion on $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Rebuild from Package.json rather than hand-editing where possible.")
    $L.Add('$adtSession = @{')
    $L.Add('    # App variables.')
    $L.Add('    AppVendor = ' + (ConvertTo-PsSingleQuoted "$($a.Vendor)".Trim()))
    $L.Add('    AppName = ' + (ConvertTo-PsSingleQuoted "$($a.Name)".Trim()))
    $L.Add('    AppVersion = ' + (ConvertTo-PsSingleQuoted "$($a.Version)".Trim()))
    $L.Add('    AppArch = ' + (ConvertTo-PsSingleQuoted "$($a.Arch)".Trim()))
    $L.Add('    AppLang = ' + (ConvertTo-PsSingleQuoted $(if ("$($a.Lang)".Trim()) { "$($a.Lang)".Trim() } else { 'EN' })))
    $L.Add('    AppRevision = ' + (ConvertTo-PsSingleQuoted $(if ("$($a.Revision)".Trim()) { "$($a.Revision)".Trim() } else { '01' })))
    $L.Add('    AppSuccessExitCodes = ' + (ConvertTo-IntArrayLiteral $i.SuccessExitCodes))
    $L.Add('    AppRebootExitCodes = ' + (ConvertTo-IntArrayLiteral $i.RebootExitCodes))
    $L.Add('    AppProcessesToClose = ' + (ConvertTo-ProcessArrayLiteral $i.ProcessesToClose))
    $L.Add('    AppScriptVersion = ' + (ConvertTo-PsSingleQuoted $(if ("$($a.ScriptVersion)".Trim()) { "$($a.ScriptVersion)".Trim() } else { '1.0.0' })))
    $L.Add("    AppScriptDate = '$(Get-Date -Format 'yyyy-MM-dd')'")
    $L.Add('    AppScriptAuthor = ' + (ConvertTo-PsSingleQuoted "$($a.Author)".Trim()))
    $L.Add('    RequireAdmin = $true')
    $L.Add('')
    $L.Add('    # Install Titles (Only set here to override defaults set by the toolkit).')
    $L.Add("    InstallName = ''")
    $L.Add("    InstallTitle = ''")
    $L.Add('')
    $L.Add('    # Script variables.')
    $L.Add('    DeployAppScriptFriendlyName = $MyInvocation.MyCommand.Name')
    $L.Add('    DeployAppScriptParameters = $PSBoundParameters')
    $L.Add("    DeployAppScriptVersion = '$ToolkitVersion'")
    $L.Add('}')
    $L.Add('')

    # ---------------- Install
    $L.Add('function Install-ADTDeployment')
    $L.Add('{'); $L.Add('    [CmdletBinding()]'); $L.Add('    param'); $L.Add('    ('); $L.Add('    )'); $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Pre-Install'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"')
    $L.Add('')
    if ($i.ShowWelcome) { foreach ($ln in (New-WelcomeBlock -Install $i)) { $L.Add($ln) } }
    if ($i.ShowProgress) { $L.Add('    ## Show Progress Message (with the default message).'); $L.Add('    Show-ADTInstallationProgress'); $L.Add('') }
    $pre = Format-UserCode -Code $i.PreScript
    if ($pre.Count -gt 0) { $L.Add('    ## Pre-install tasks.'); foreach ($ln in $pre) { $L.Add($ln) }; $L.Add('') }
    $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Install'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = $adtSession.DeploymentType')
    $L.Add('')
    foreach ($ln in (New-InstallActionCode -Def $Def -Action Install)) { $L.Add($ln) }
    $L.Add('')
    $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Post-Install'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"')
    $L.Add('')
    $post = Format-UserCode -Code $i.PostScript
    if ($post.Count -gt 0) { $L.Add('    ## Post-install tasks.'); foreach ($ln in $post) { $L.Add($ln) }; $L.Add('') }
    if ($i.ShowCompletionPrompt)
    {
        $L.Add('    ## Display a message at the end of the install (suppressed automatically in Silent mode).')
        $L.Add('    Show-ADTInstallationPrompt -Message ' + (ConvertTo-PsSingleQuoted "$($a.Name) $($a.Version) has been installed.") + ' -ButtonRightText ''OK'' -Icon Information -NoWait')
    }
    $L.Add('}')
    $L.Add('')

    # ---------------- Uninstall
    $u = $Def.Uninstall
    $L.Add('function Uninstall-ADTDeployment')
    $L.Add('{'); $L.Add('    [CmdletBinding()]'); $L.Add('    param'); $L.Add('    ('); $L.Add('    )'); $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Pre-Uninstall'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"')
    $L.Add('')
    $L.Add('    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.')
    $L.Add('    if ($adtSession.AppProcessesToClose.Count -gt 0)')
    $L.Add('    {')
    $L.Add('        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60')
    $L.Add('    }')
    $L.Add('')
    if ($i.ShowProgress) { $L.Add('    ## Show Progress Message (with the default message).'); $L.Add('    Show-ADTInstallationProgress'); $L.Add('') }
    $upre = Format-UserCode -Code $u.PreScript
    if ($upre.Count -gt 0) { $L.Add('    ## Pre-uninstall tasks.'); foreach ($ln in $upre) { $L.Add($ln) }; $L.Add('') }
    $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Uninstall'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = $adtSession.DeploymentType')
    $L.Add('')
    foreach ($ln in (New-UninstallActionCode -Def $Def)) { $L.Add($ln) }
    $L.Add('')
    $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Post-Uninstallation'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"')
    $L.Add('')
    $upost = Format-UserCode -Code $u.PostScript
    if ($upost.Count -gt 0) { $L.Add('    ## Post-uninstall tasks.'); foreach ($ln in $upost) { $L.Add($ln) } }
    else { $L.Add('    ## <Perform Post-Uninstallation tasks here>') }
    $L.Add('}')
    $L.Add('')

    # ---------------- Repair
    $L.Add('function Repair-ADTDeployment')
    $L.Add('{'); $L.Add('    [CmdletBinding()]'); $L.Add('    param'); $L.Add('    ('); $L.Add('    )'); $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Pre-Repair'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = "Pre-$($adtSession.DeploymentType)"')
    $L.Add('')
    $L.Add('    ## If there are processes to close, show Welcome Message with a 60 second countdown before automatically closing.')
    $L.Add('    if ($adtSession.AppProcessesToClose.Count -gt 0)')
    $L.Add('    {')
    $L.Add('        Show-ADTInstallationWelcome -CloseProcesses $adtSession.AppProcessesToClose -CloseProcessesCountdown 60')
    $L.Add('    }')
    $L.Add('')
    if ($i.ShowProgress) { $L.Add('    ## Show Progress Message (with the default message).'); $L.Add('    Show-ADTInstallationProgress'); $L.Add('') }
    $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Repair'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = $adtSession.DeploymentType')
    $L.Add('')
    foreach ($ln in (New-InstallActionCode -Def $Def -Action Repair)) { $L.Add($ln) }
    $L.Add('')
    $L.Add('')
    $L.Add("    $sep"); $L.Add('    ## MARK: Post-Repair'); $L.Add("    $sep")
    $L.Add('    $adtSession.InstallPhase = "Post-$($adtSession.DeploymentType)"')
    $L.Add('')
    $L.Add('    ## <Perform Post-Repair tasks here>')
    $L.Add('}')
    $L.Add('')
    $L.Add('')
    return ($L -join "`r`n")
}

function New-InvokeAppDeployToolkitScript
{
    # Merges the generated sections into the real template so the bootstrap always matches the shipped toolkit.
    param([Parameter(Mandatory)]$Def, [Parameter(Mandatory)][string]$TemplatePath)
    $lines = [System.IO.File]::ReadAllLines($TemplatePath)
    $iVar  = -1
    $iInit = -1
    for ($n = 0; $n -lt $lines.Count; $n++)
    {
        if ($iVar  -lt 0 -and $lines[$n] -match '^## MARK: Variables')      { $iVar  = $n }
        if ($iInit -lt 0 -and $lines[$n] -match '^## MARK: Initialization') { $iInit = $n }
    }
    if ($iVar -lt 1 -or $iInit -lt 1 -or $iInit -le $iVar)
    {
        throw "The PSADT template at '$TemplatePath' does not have the expected '## MARK: Variables' / '## MARK: Initialization' layout. Update PSADT Packager for this toolkit version."
    }
    $toolkitVersion = '4.1.8'
    $m = [regex]::Match(($lines -join "`n"), "DeployAppScriptVersion\s*=\s*'([^']+)'")
    if ($m.Success) { $toolkitVersion = $m.Groups[1].Value }

    $head = $lines[0..($iVar - 2)]
    $tail = $lines[($iInit - 1)..($lines.Count - 1)]
    $body = New-DeploymentSections -Def $Def -ToolkitVersion $toolkitVersion
    return (($head -join "`r`n") + "`r`n" + $body + ($tail -join "`r`n") + "`r`n")
}

#endregion

#region ---------------------------------------------------------------- Code generation: detection script

$script:DetectionCommon = @'
function ConvertTo-NormalizedVersion
{
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match(($Text -replace ',', '.').Trim(), '\d+(\.\d+){0,3}')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value.Split('.') | ForEach-Object { [int64]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    return New-Object System.Version -ArgumentList ([int]$parts[0]), ([int]$parts[1]), ([int]$parts[2]), ([int]$parts[3])
}

function Test-VersionAtLeast
{
    param([string]$Actual, [string]$Minimum)
    if ([string]::IsNullOrWhiteSpace($Minimum)) { return $true }
    $min = ConvertTo-NormalizedVersion $Minimum
    if ($null -eq $min) { return $true }
    $act = ConvertTo-NormalizedVersion $Actual
    if ($null -eq $act) { return $false }
    return ($act -ge $min)
}

function Get-UninstallEntry
{
    # Enumerates HKLM (64-bit and 32-bit views) and HKCU uninstall entries.
    $roots = @(
        @{ Hive = 'LocalMachine'; View = 'Registry64' },
        @{ Hive = 'LocalMachine'; View = 'Registry32' },
        @{ Hive = 'CurrentUser';  View = 'Default' }
    )
    foreach ($r in $roots)
    {
        try
        {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$r.Hive, [Microsoft.Win32.RegistryView]$r.View)
            $key  = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $key) { continue }
            foreach ($name in $key.GetSubKeyNames())
            {
                $sub = $key.OpenSubKey($name)
                if (-not $sub) { continue }
                [pscustomobject]@{
                    KeyName        = $name
                    DisplayName    = [string]$sub.GetValue('DisplayName')
                    DisplayVersion = [string]$sub.GetValue('DisplayVersion')
                    Publisher      = [string]$sub.GetValue('Publisher')
                    Location       = "$($r.Hive)\$($r.View)"
                }
                $sub.Close()
            }
            $key.Close()
        }
        catch { }
    }
}

'@

function New-DetectionScript
{
    param([Parameter(Mandatory)]$Def)
    $d = $Def.Detection
    $a = $Def.App
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('<#')
    $L.Add('    Intune custom detection script - generated by PSADT Packager ' + $script:PackagerVersion)
    $L.Add("    Application : $($a.Vendor) $($a.Name) $($a.Version)".TrimEnd())
    $L.Add("    Generated   : $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    $L.Add('')
    $L.Add('    Intune contract: exit code 0 AND text on STDOUT = detected; anything else = not detected.')
    $L.Add('    Runs as SYSTEM in a 64-bit host by default; registry checks cover both 64-bit and 32-bit views.')
    $L.Add('#>')
    $L.Add('')

    switch ($d.Type)
    {
        'MSI'
        {
            $code = "$($d.ProductCode)".Trim()
            if (-not $code) { $code = "$($Def.Install.ProductCode)".Trim() }
            $L.Add('$ProductCode = ' + (ConvertTo-PsSingleQuoted $code))
            $L.Add('$MinVersion  = ' + (ConvertTo-PsSingleQuoted "$($d.MinVersion)".Trim()) + '   # empty = any version')
            $L.Add('')
            $L.Add($script:DetectionCommon.TrimEnd())
            $L.Add('')
            $L.Add('$entry = Get-UninstallEntry | Where-Object { $_.KeyName -eq $ProductCode } | Select-Object -First 1')
            $L.Add('if ($entry -and (Test-VersionAtLeast -Actual $entry.DisplayVersion -Minimum $MinVersion))')
            $L.Add('{')
            $L.Add('    Write-Output "Detected: $($entry.DisplayName) $($entry.DisplayVersion) [$ProductCode] ($($entry.Location))"')
            $L.Add('    exit 0')
            $L.Add('}')
            $L.Add('exit 1')
        }
        'Registry'
        {
            $mode = if ($script:MatchModeCodes -contains $d.MatchMode) { $d.MatchMode } else { 'Wildcard' }
            $L.Add('$DisplayName = ' + (ConvertTo-PsSingleQuoted "$($d.DisplayName)".Trim()))
            $L.Add('$MatchMode   = ' + (ConvertTo-PsSingleQuoted $mode) + '   # Exact | Wildcard (-like) | Regex (-match)')
            $L.Add('$MinVersion  = ' + (ConvertTo-PsSingleQuoted "$($d.MinVersion)".Trim()) + '   # empty = any version')
            $L.Add('')
            $L.Add($script:DetectionCommon.TrimEnd())
            $L.Add('')
            $L.Add('$found = @(Get-UninstallEntry | Where-Object {')
            $L.Add('    $name = $_.DisplayName')
            $L.Add('    if (-not $name) { return $false }')
            $L.Add("    if (`$MatchMode -eq 'Exact') { return (`$name -eq `$DisplayName) }")
            $L.Add("    if (`$MatchMode -eq 'Regex') { return (`$name -match `$DisplayName) }")
            $L.Add('    return ($name -like $DisplayName)')
            $L.Add('})')
            $L.Add('$best = $found | Sort-Object { ConvertTo-NormalizedVersion $_.DisplayVersion } -Descending | Select-Object -First 1')
            $L.Add('if ($best -and (Test-VersionAtLeast -Actual $best.DisplayVersion -Minimum $MinVersion))')
            $L.Add('{')
            $L.Add('    Write-Output "Detected: $($best.DisplayName) $($best.DisplayVersion) ($($best.Location))"')
            $L.Add('    exit 0')
            $L.Add('}')
            $L.Add('exit 1')
        }
        'File'
        {
            $L.Add('$FilePath     = "' + (ConvertTo-PsExpandableString "$($d.FilePath)".Trim()) + '"')
            $L.Add('$MinVersion   = ' + (ConvertTo-PsSingleQuoted "$($d.MinVersion)".Trim()) + '   # empty = any version')
            $L.Add('$CheckVersion = ' + $(if ($d.CheckFileVersion) { '$true' } else { '$false' }))
            $L.Add('')
            $L.Add($script:DetectionCommon.TrimEnd())
            $L.Add('')
            $L.Add('if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { exit 1 }')
            $L.Add('if (-not $CheckVersion -or [string]::IsNullOrWhiteSpace($MinVersion))')
            $L.Add('{')
            $L.Add('    Write-Output "Detected: $FilePath"')
            $L.Add('    exit 0')
            $L.Add('}')
            $L.Add('$vi = (Get-Item -LiteralPath $FilePath).VersionInfo')
            $L.Add('$actual = ''''')
            $L.Add('if ($vi.PSObject.Properties[''FileVersionRaw''] -and $vi.FileVersionRaw) { $actual = $vi.FileVersionRaw.ToString() }')
            $L.Add('if (-not $actual) { $actual = "$($vi.FileVersion)" }')
            $L.Add('if (-not $actual) { $actual = "$($vi.ProductVersion)" }')
            $L.Add('if (Test-VersionAtLeast -Actual $actual -Minimum $MinVersion)')
            $L.Add('{')
            $L.Add('    Write-Output "Detected: $FilePath version $actual"')
            $L.Add('    exit 0')
            $L.Add('}')
            $L.Add('exit 1')
        }
        'MSIX'
        {
            $L.Add('$PackageName = ' + (ConvertTo-PsSingleQuoted "$($d.PackageName)".Trim()) + '   # package identity name')
            $L.Add('$MinVersion  = ' + (ConvertTo-PsSingleQuoted "$($d.MinVersion)".Trim()) + '   # empty = any version')
            $L.Add('')
            $L.Add($script:DetectionCommon.TrimEnd())
            $L.Add('')
            $L.Add('$found = $null')
            $L.Add('try { $found = Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -eq $PackageName } | Select-Object -First 1 } catch { }')
            $L.Add('if ($found -and (Test-VersionAtLeast -Actual $found.Version -Minimum $MinVersion))')
            $L.Add('{')
            $L.Add('    Write-Output "Detected provisioned package: $($found.PackageName)"')
            $L.Add('    exit 0')
            $L.Add('}')
            $L.Add('$pkg = $null')
            $L.Add('try { $pkg = Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction Stop | Sort-Object { ConvertTo-NormalizedVersion $_.Version } -Descending | Select-Object -First 1 }')
            $L.Add('catch { try { $pkg = Get-AppxPackage -Name $PackageName -ErrorAction Stop | Sort-Object { ConvertTo-NormalizedVersion $_.Version } -Descending | Select-Object -First 1 } catch { } }   # -AllUsers needs elevation; fall back to the current user')
            $L.Add('if ($pkg -and (Test-VersionAtLeast -Actual $pkg.Version -Minimum $MinVersion))')
            $L.Add('{')
            $L.Add('    Write-Output "Detected installed package: $($pkg.PackageFullName)"')
            $L.Add('    exit 0')
            $L.Add('}')
            $L.Add('exit 1')
        }
        'Script'
        {
            $L.Add(("$($d.Script)" -replace "`r`n", "`n").Trim().Replace("`n", "`r`n"))
        }
    }
    return (($L -join "`r`n") + "`r`n")
}

#endregion

#region ---------------------------------------------------------------- README

function New-PackageReadme
{
    param([Parameter(Mandatory)]$Def, [string]$FolderName, [string]$DetectFileName, [string]$ToolkitVersion, [string]$IntuneWinName)
    $a = $Def.App
    $mode = if ($script:DeployModeChoices -contains $Def.Output.DeployMode) { $Def.Output.DeployMode } else { 'Silent' }
    $installCmd   = Get-IntuneInstallCommand -Def $Def
    $uninstallCmd = Get-IntuneUninstallCommand -Def $Def
    $rcText = ((Get-IntuneReturnCodes -Def $Def) | ForEach-Object { "$($_.returnCode) = $($_.type)" }) -join '; '
    $minOsIdx = [Array]::IndexOf($script:MinOsCodes, "$($Def.Intune.MinimumOs)")
    $minOsText = if ($minOsIdx -ge 0) { $script:MinOsLabels[$minOsIdx] } else { 'Windows 10 1809' }
    $runAsIdx = [Array]::IndexOf($script:RunAsChoices, "$($Def.Intune.RunAsAccount)")
    $runAsText = if ($runAsIdx -ge 0) { $script:RunAsLabels[$runAsIdx] } else { 'System (device context)' }
    $restartIdx = [Array]::IndexOf($script:RestartChoices, "$($Def.Intune.RestartBehavior)")
    $restartText = if ($restartIdx -ge 0) { $script:RestartLabels[$restartIdx] } else { 'Determine behavior based on return codes' }
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# $($a.Vendor) $($a.Name) $($a.Version)".Replace('#  ', '# ').TrimEnd())
    $L.Add('')
    $L.Add("Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by PSADT Packager $script:PackagerVersion using PSAppDeployToolkit $ToolkitVersion.")
    $L.Add('')
    $L.Add('## Intune Win32 app settings')
    $L.Add('')
    $L.Add('| Setting | Value |')
    $L.Add('| --- | --- |')
    $L.Add("| Name | $(Get-IntuneDisplayName -Def $Def) |")
    $L.Add("| Publisher | $(if ("$($Def.Intune.Publisher)".Trim()) { "$($Def.Intune.Publisher)".Trim() } else { "$($a.Vendor)".Trim() }) |")
    $L.Add("| App version | $("$($a.Version)".Trim()) |")
    $L.Add('| Package source folder (`.intunewin` content) | `Package\` |')
    $L.Add('| Setup file (IntuneWinAppUtil `-s`) | `Invoke-AppDeployToolkit.exe` |')
    $L.Add("| Install command | ``$installCmd`` |")
    $L.Add("| Uninstall command | ``$uninstallCmd`` |")
    $L.Add("| Install behavior | $runAsText |")
    $L.Add("| Device restart behavior | $restartText |")
    $L.Add("| Minimum operating system | $minOsText |")
    $L.Add("| Applicable architectures | $(Get-IntuneArchitectures -Def $Def) |")
    $L.Add("| Allow uninstall (Available assignments) | $(if ($Def.Intune.AllowAvailableUninstall) { 'Yes' } else { 'No' }) |")
    $L.Add("| Detection rule | Use a custom detection script: ``$DetectFileName`` (Run as 32-bit: No, Enforce signature check: No) |")
    $L.Add("| Return codes | $rcText |")
    if ($IntuneWinName) { $L.Add("| Built package | ``Intune\$IntuneWinName`` |") }
    $L.Add('')
    $L.Add('Publish these settings straight from the Intune tab (or `-Publish`) instead of retyping them.')
    $L.Add('')
    $L.Add('`-DeployMode Silent` never shows dialogs (Required assignments). `Auto` (toolkit default) shows the welcome/progress dialogs when a user is logged on and suppresses them otherwise; use it for Available assignments where you want close-app prompts and deferrals.')
    $L.Add('')
    $L.Add('## Contents')
    $L.Add('')
    $L.Add('| Path | Purpose |')
    $L.Add('| --- | --- |')
    $L.Add('| `Package\Invoke-AppDeployToolkit.ps1` | Generated deployment script (Install / Uninstall / Repair) |')
    $L.Add('| `Package\Invoke-AppDeployToolkit.exe` | Toolkit launcher (handles 32/64-bit host and exit codes) |')
    $L.Add('| `Package\Files\` | Installer and supporting files referenced by the script |')
    $L.Add('| `Package\SupportFiles\` | Extra content (config files, fonts, licences) |')
    $L.Add('| `Package\PSAppDeployToolkit\` | Toolkit module |')
    $L.Add("| ``$DetectFileName`` | Intune custom detection script |")
    $L.Add('| `Package.json` | Package definition; open it in PSADT Packager to change anything and rebuild |')
    $L.Add('')
    $L.Add('## Test locally (elevated)')
    $L.Add('')
    $L.Add('```powershell')
    $L.Add('.\Package\Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Interactive')
    $L.Add(".\$DetectFileName; `$LASTEXITCODE   # 0 = detected")
    $L.Add('.\Package\Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode Silent')
    $L.Add('```')
    $L.Add('')
    $L.Add('Toolkit logs: `C:\Windows\Logs\Software\`.')
    $L.Add('')
    $L.Add('## Rebuild')
    $L.Add('')
    $L.Add('```powershell')
    $L.Add('.\PsadtPackager.ps1 -Definition ".\Package.json" -NoGui -Force')
    $L.Add('```')
    $L.Add('')
    return (($L -join "`r`n") + "`r`n")
}

#endregion

#region ---------------------------------------------------------------- Toolkit acquisition and build

function Import-PsadtModule
{
    # Returns the PSAppDeployToolkit module info (installed, cached, or freshly downloaded).
    if (-not (Test-Path -LiteralPath $script:ModuleCache)) { New-Item -ItemType Directory -Path $script:ModuleCache -Force | Out-Null }
    if (($env:PSModulePath -split ';') -notcontains $script:ModuleCache) { $env:PSModulePath = "$script:ModuleCache;$env:PSModulePath" }

    $mod = Get-Module -ListAvailable -Name PSAppDeployToolkit | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod)
    {
        Write-PackagerLog "PSAppDeployToolkit is not installed. Downloading the latest release from the PowerShell Gallery into $script:ModuleCache ..."
        try
        {
            Save-Module -Name PSAppDeployToolkit -Path $script:ModuleCache -Force -ErrorAction Stop
        }
        catch
        {
            throw "Could not download PSAppDeployToolkit from the PowerShell Gallery: $($_.Exception.Message). Install it manually (Install-Module PSAppDeployToolkit) or copy it to $script:ModuleCache."
        }
        $mod = Get-Module -ListAvailable -Name PSAppDeployToolkit | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $mod) { throw 'PSAppDeployToolkit was downloaded but could not be located afterwards.' }
    }
    # Install-Module puts the toolkit in Documents, which OneDrive often syncs and may keep online-only, so every build
    # (the template copies the whole module) would wait for OneDrive. Build from a local copy in the cache instead.
    $inCache = { param($m) $m.ModuleBase.StartsWith($script:ModuleCache.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) }
    $oneDrive = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' })
    if (-not (& $inCache $mod) -and @($oneDrive | Where-Object { $mod.ModuleBase.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
    {
        $target = Join-Path $script:ModuleCache "PSAppDeployToolkit\$($mod.Version)"
        if (-not (Test-Path -LiteralPath (Join-Path $target 'PSAppDeployToolkit.psd1')))
        {
            Write-PackagerLog "Copying PSAppDeployToolkit $($mod.Version) from OneDrive ($($mod.ModuleBase)) to $target, once, so builds don't wait for OneDrive"
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Copy-Item -Path (Join-Path $mod.ModuleBase '*') -Destination $target -Recurse -Force -ErrorAction Stop
        }
        $local = Get-Module -ListAvailable -Name PSAppDeployToolkit | Where-Object { $_.Version -eq $mod.Version -and (& $inCache $_) } | Select-Object -First 1
        if ($local) { $mod = $local }
    }
    $loaded = Get-Module -Name PSAppDeployToolkit
    if (-not $loaded -or $loaded.Version -ne $mod.Version)
    {
        Write-PackagerLog "Importing PSAppDeployToolkit $($mod.Version) from $($mod.ModuleBase)"
        Import-Module -Name $mod.Path -Force -ErrorAction Stop
    }
    return $mod
}

function Copy-SourceItem
{
    param([string]$Source, [string]$DestinationDir)
    if ("$Source".EndsWith('\*'))
    {
        $dir = $Source.Substring(0, $Source.Length - 2)
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "Source folder not found: $dir" }
        Get-ChildItem -LiteralPath $dir -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $DestinationDir -Recurse -Force }
        Write-PackagerLog "Copied contents of $dir"
    }
    elseif (Test-Path -LiteralPath $Source -PathType Container)
    {
        $target = Join-Path $DestinationDir (Split-Path -Path $Source -Leaf)
        Copy-Item -LiteralPath $Source -Destination $target -Recurse -Force
        Write-PackagerLog "Copied folder $Source"
    }
    elseif (Test-Path -LiteralPath $Source -PathType Leaf)
    {
        Copy-Item -LiteralPath $Source -Destination $DestinationDir -Force
        Write-PackagerLog "Copied $Source"
    }
    else
    {
        throw "Source not found: $Source"
    }
}

function Resolve-IntuneWinAppUtil
{
    param([string]$Configured)
    $candidates = @()
    if ($Configured) { $candidates += $Configured }
    $candidates += (Join-Path $script:AppDataDir 'IntuneWinAppUtil.exe')
    $cmd = Get-Command -Name IntuneWinAppUtil.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c } }
    return $null
}

function Get-IntuneWinAppUtil
{
    # Downloads the Microsoft Win32 Content Prep Tool into the packager's app-data folder.
    $target = Join-Path $script:AppDataDir 'IntuneWinAppUtil.exe'
    if (-not (Test-Path -LiteralPath $script:AppDataDir)) { New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null }
    Write-PackagerLog "Downloading IntuneWinAppUtil.exe from $script:IntuneWinUrl"
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $script:IntuneWinUrl -OutFile $target -UseBasicParsing -ErrorAction Stop
    Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
    Write-PackagerLog "Saved to $target"
    return $target
}

function Invoke-PackageBuild
{
    param([Parameter(Mandatory)]$Def, [switch]$Force)

    $problems = Test-PackageDefinition -Def $Def
    if ($problems.Count -gt 0) { throw ("Definition is not complete:`n - " + ($problems -join "`n - ")) }

    $paths      = Get-PackagePaths -Def $Def
    $folderName = $paths.FolderName
    $root       = $paths.Root
    $pkg        = $paths.Package
    $filesDir   = $paths.FilesDir
    $supportDir = $paths.SupportDir
    $detectName = $paths.DetectName

    Write-PackagerLog "Building package '$folderName' in $root"
    if (Test-Path -LiteralPath $pkg)
    {
        if (-not $Force) { throw "Package folder already exists: $pkg (use Force / Overwrite to rebuild)." }
        Write-PackagerLog "Removing existing $pkg"
        Remove-Item -LiteralPath $pkg -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }

    $mod = Import-PsadtModule

    # Windows PowerShell 5.1 cannot copy beyond MAX_PATH; the toolkit tree is deep, so check before creating anything.
    $deepest = 0
    Get-ChildItem -LiteralPath $mod.ModuleBase -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($mod.ModuleBase.Length)
        if ($rel.Length -gt $deepest) { $deepest = $rel.Length }
    }
    $longest = (Join-Path $pkg 'PSAppDeployToolkit').Length + $deepest
    if ($longest -gt 250)
    {
        throw "Destination path is too long: the deepest toolkit file would be $longest characters (limit 250). Use a shorter destination such as C:\Packages (current package root: $root)."
    }

    Write-PackagerLog "Creating PSADT $($mod.Version) template"
    New-ADTTemplate -Destination $root -Name 'Package' -Force -ErrorAction Stop | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $pkg 'Invoke-AppDeployToolkit.ps1'))) { throw "New-ADTTemplate did not produce $pkg\Invoke-AppDeployToolkit.ps1" }
    foreach ($d in @($filesDir, $supportDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

    Write-PackagerLog 'Copying source files'
    foreach ($src in @($Def.Sources.Files | Where-Object { "$_".Trim() }))        { Copy-SourceItem -Source $src -DestinationDir $filesDir }
    foreach ($src in @($Def.Sources.SupportFiles | Where-Object { "$_".Trim() })) { Copy-SourceItem -Source $src -DestinationDir $supportDir }
    # Drop the toolkit's zero-byte placeholder files once real content is in place.
    Get-ChildItem -LiteralPath $filesDir, $supportDir -Filter 'Add *Files Here.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -eq 0 } | Remove-Item -Force -ErrorAction SilentlyContinue

    if ($Def.Install.Type -in @('MSI', 'EXE', 'Script', 'MSIX'))
    {
        $mainFile = Join-Path $filesDir $Def.Install.File
        if (-not (Test-Path -LiteralPath $mainFile -PathType Leaf)) { throw "Installer '$($Def.Install.File)' is not in Package\Files after copying sources. Add it on the Source files tab." }
    }
    foreach ($t in @($Def.Install.Transforms | Where-Object { "$_".Trim() }))
    {
        if (-not (Test-Path -LiteralPath (Join-Path $filesDir $t.Trim()) -PathType Leaf)) { throw "Transform '$t' is not in Package\Files." }
    }
    if ($Def.Uninstall.Type -eq 'Script' -and -not (Test-Path -LiteralPath (Join-Path $filesDir $Def.Uninstall.File.Trim()) -PathType Leaf))
    {
        throw "Uninstall script '$($Def.Uninstall.File)' is not in Package\Files."
    }

    $templatePath = Join-Path $pkg 'Invoke-AppDeployToolkit.ps1'
    Write-PackagerLog 'Generating Invoke-AppDeployToolkit.ps1'
    $script = New-InvokeAppDeployToolkitScript -Def $Def -TemplatePath $templatePath
    Write-Utf8File -Path $templatePath -Content $script

    Write-PackagerLog "Generating $detectName"
    Write-Utf8File -Path (Join-Path $root $detectName) -Content (New-DetectionScript -Def $Def)

    # Syntax-check both generated scripts.
    foreach ($f in @($templatePath, (Join-Path $root $detectName)))
    {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0)
        {
            throw "Generated script has syntax errors ($f):`n" + (($errors | ForEach-Object { " line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n")
        }
    }

    Save-PackageDefinition -Def $Def -Path (Join-Path $root 'Package.json')

    $intuneWinName = $null
    if ($Def.Output.BuildIntuneWin)
    {
        $tool = Resolve-IntuneWinAppUtil -Configured $Def.Output.IntuneWinAppUtil
        if (-not $tool) { throw 'IntuneWinAppUtil.exe was not found. Set its path on the Build tab or use the Download button.' }
        $intuneDir = $paths.IntuneDir
        if (-not (Test-Path -LiteralPath $intuneDir)) { New-Item -ItemType Directory -Path $intuneDir -Force | Out-Null }
        $intuneWinName = $paths.IntuneWinName
        $rawOut = Join-Path $intuneDir 'Invoke-AppDeployToolkit.intunewin'
        $final  = Join-Path $intuneDir $intuneWinName
        foreach ($f in @($rawOut, $final)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        Write-PackagerLog "Building $intuneWinName with $tool"
        $output = & $tool -c $pkg -s 'Invoke-AppDeployToolkit.exe' -o $intuneDir -q 2>&1
        foreach ($line in @($output)) { if ("$line".Trim()) { Write-PackagerLog "  $line" } }
        if (-not (Test-Path -LiteralPath $rawOut)) { throw "IntuneWinAppUtil did not produce $rawOut (exit code $LASTEXITCODE)." }
        Rename-Item -LiteralPath $rawOut -NewName $intuneWinName -Force
        $portalName = Get-IntuneDisplayName -Def $Def
        Set-IntuneWinDisplayName -Path $final -Name $portalName
        Write-PackagerLog "Created $final (the Add App wizard will name it '$portalName')"
    }

    Write-Utf8File -Path (Join-Path $root 'README.md') -Content (New-PackageReadme -Def $Def -FolderName $folderName -DetectFileName $detectName -ToolkitVersion "$($mod.Version)" -IntuneWinName $intuneWinName)

    # The exact Win32 app body, so the settings can be reviewed or posted to Graph without rebuilding.
    $appPayload = New-IntuneAppPayload -Def $Def -DetectionScript ([System.IO.File]::ReadAllText((Join-Path $root $detectName))) -IntuneWinFileName $paths.IntuneWinName
    Write-Utf8File -Path (Join-Path $root 'IntuneApp.json') -Content (ConvertTo-IntuneAppJson -Payload $appPayload)

    Write-PackagerLog "Done: $root"
    return $root
}

#endregion

#region ---------------------------------------------------------------- Windows Sandbox: run installers and packages headlessly as SYSTEM

# Runs inside the sandbox as SYSTEM (wsb exec -r System) - the same account Intune installs with. Everything it touches is
# thrown away when the sandbox stops. Two modes:
#   Install  - run one installer command, record what it changed (uninstall entries, folders, shortcuts, registry keys,
#              services, scheduled tasks), run the detection script, then prove the registered uninstall.
#   Validate - run a finished PSADT package end to end: install, detect, uninstall, detect again.
$script:SandboxProbeScript = @'
# Run-Probe.ps1 - executed inside Windows Sandbox by PSADT Packager. Reads C:\Probe\config.json, writes
# C:\Probe\result.json and C:\Probe\probe.log (C:\Probe is the host's run folder; C:\Source is the read-only input).
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$probeDir   = 'C:\Probe'
$srcDir     = 'C:\Source'
$workDir    = 'C:\Work'
$logPath    = Join-Path $probeDir 'probe.log'
$resultPath = Join-Path $probeDir 'result.json'

function Write-ProbeLog([string]$Message)
{
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

$result = [ordered]@{
    Mode             = ''
    Label            = ''
    Started          = (Get-Date).ToString('s')
    Help             = $null
    Install          = $null
    InstallSucceeded = $false
    NewEntries       = @()
    PrimaryEntry     = $null
    Footprint        = $null
    Detection        = $null
    Uninstall        = $null
    Validation       = $null
    Error            = $null
}

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class ProbeWin
{
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc f, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, StringBuilder l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr h, int index);
    [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
    const uint WM_GETTEXT = 0x000D;
    const uint WM_GETTEXTLENGTH = 0x000E;
    const uint SMTO_ABORTIFHUNG = 0x0002;

    // The window's own WS_VISIBLE bit: set by ShowWindow even on SYSTEM's non-interactive desktop (where
    // IsWindowVisible is false for everything). Quiet-mode UIs (WiX Burn) build their window but never show it.
    public static bool Shown(long handle)
    {
        return (GetWindowLong32(new IntPtr(handle), -16) & 0x10000000) != 0;
    }

    // WM_GETTEXT works across processes (GetWindowText does not for controls), and on the non-interactive desktop.
    public static string Text(IntPtr h)
    {
        IntPtr len;
        if (SendMessageTimeout(h, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 500, out len) == IntPtr.Zero) return "";
        long n = len.ToInt64();
        if (n <= 0) return "";
        if (n > 8192) n = 8192;
        var sb = new StringBuilder((int)n + 1);
        IntPtr r;
        SendMessageTimeout(h, WM_GETTEXT, new IntPtr(sb.Capacity), sb, SMTO_ABORTIFHUNG, 500, out r);
        return sb.ToString();
    }

    public static string ClassOf(IntPtr h)
    {
        var sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    // Top-level windows as "pid|handle|class|title". SYSTEM runs on a non-interactive desktop, so nothing is ever
    // visible there; visibility is not checked.
    public static List<string> TopWindows()
    {
        var list = new List<string>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            list.Add(pid.ToString() + "|" + h.ToInt64().ToString() + "|" + ClassOf(h) + "|" + Text(h));
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static List<string> ChildTexts(long handle)
    {
        var list = new List<string>();
        EnumChildWindows(new IntPtr(handle), delegate (IntPtr h, IntPtr l) {
            string t = Text(h);
            if (!string.IsNullOrEmpty(t)) list.Add(t);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // The control and every parent up to the top-level window have WS_VISIBLE (pages are often hidden panels).
    static bool ChainShown(IntPtr h, IntPtr top)
    {
        for (int depth = 0; h != IntPtr.Zero && h != top && depth < 32; depth++)
        {
            if ((GetWindowLong32(h, -16) & 0x10000000) == 0) return false;
            h = GetParent(h);
        }
        return true;
    }

    // Only the controls on show: WiX Burn's window holds every page (help, progress, options ...) and hides the rest, so
    // all of its texts together would quote its help page while it is only showing progress.
    public static List<string> ShownChildTexts(long handle)
    {
        var list = new List<string>();
        EnumChildWindows(new IntPtr(handle), delegate (IntPtr h, IntPtr l) {
            if (!ChainShown(h, new IntPtr(handle))) return true;
            string t = Text(h);
            if (!string.IsNullOrEmpty(t)) list.Add(t);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    // Files created since sinceUtc under the roots (folders under a skip prefix left out, junctions not followed):
    // "count|newest file|partial" - partial when maxMs ran out before every folder was seen.
    public static string NewFilesSince(string[] roots, string[] skip, DateTime sinceUtc, int maxMs)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        long count = 0;
        DateTime newest = DateTime.MinValue;
        string newestPath = "";
        var stack = new Stack<string>();
        foreach (string r in roots) { if (!string.IsNullOrEmpty(r) && System.IO.Directory.Exists(r)) stack.Push(r); }
        while (stack.Count > 0 && sw.ElapsedMilliseconds < maxMs)
        {
            string dir = stack.Pop();
            try
            {
                var di = new System.IO.DirectoryInfo(dir);
                foreach (var f in di.EnumerateFiles())
                {
                    DateTime c = f.CreationTimeUtc;
                    if (c >= sinceUtc) { count++; if (c > newest) { newest = c; newestPath = f.FullName; } }
                }
                foreach (var d in di.EnumerateDirectories())
                {
                    if ((d.Attributes & System.IO.FileAttributes.ReparsePoint) != 0) continue;
                    bool skipped = false;
                    foreach (string s in skip) { if ((d.FullName + "\\").StartsWith(s, StringComparison.OrdinalIgnoreCase)) { skipped = true; break; } }
                    if (!skipped) stack.Push(d.FullName);
                }
            }
            catch { }
        }
        return count + "|" + newestPath + "|" + (stack.Count > 0 ? "partial" : "");
    }

    // A window showing a progress bar is reporting progress (/passive modes), not waiting for a click.
    public static bool ShowsProgress(long handle)
    {
        bool found = false;
        EnumChildWindows(new IntPtr(handle), delegate (IntPtr h, IntPtr l) {
            if (ClassOf(h).IndexOf("progress", StringComparison.OrdinalIgnoreCase) >= 0 && ChainShown(h, new IntPtr(handle))) { found = true; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // A window that waits for a person has controls: a button, or several labelled controls (message boxes, wizards).
    // Helper windows (WiX Burn's quiet-mode window, message pumps) have none.
    public static bool LooksInteractive(long handle)
    {
        int buttons = 0, texts = 0;
        EnumChildWindows(new IntPtr(handle), delegate (IntPtr h, IntPtr l) {
            if (ClassOf(h).IndexOf("Button", StringComparison.OrdinalIgnoreCase) >= 0) buttons++;
            if (!string.IsNullOrEmpty(Text(h))) texts++;
            return true;
        }, IntPtr.Zero);
        return buttons > 0 || texts >= 2;
    }
}
"@

# Where installs write: the heartbeat counts files created here since the run began, so the log shows whether an
# install is moving. ProgramData\Microsoft is Windows' own busy corner; its Start menu is counted on its own.
$ProgressRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:SystemRoot 'Installer')) | Where-Object { $_ } | Select-Object -Unique
$ProgressSkip  = @('Microsoft', 'USOShared', 'USOPrivate', 'Packages', 'regid.1991-06.com.microsoft') | ForEach-Object { (Join-Path $env:ProgramData $_) + '\' }

# Helper windows every GUI process owns; they say nothing about whether an installer is waiting for input.
$IgnoredWindowClasses = @('IME', 'MSCTFIME UI', 'GDI+ Hook Window Class', 'OleMainThreadWndClass', 'CicMarshalWndClass', 'tooltips_class32',
    'ConsoleWindowClass', 'PseudoConsoleWindow', 'ThumbnailDeviceHelperWnd', 'Shell_TrayWnd', 'WorkerW', 'Progman', 'ComboLBox', 'TApplication')
$IgnoredWindowTitles  = '^(|Default IME|MSCTFIME UI|GDI\+ Window.*|\.NET-BroadcastEventWindow.*|MediaContextNotificationWindow|SystemResourceNotifyWindow|DDE Server Window|OleMainThreadWndName|Task Host Window|WinEventWindow|Hidden Window|Theme manager|BroadcastListenerWindow|UxdService)$'

function Get-ProcessTable
{
    $t = @{}
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate, KernelModeTime, UserModeTime, ReadTransferCount, WriteTransferCount, OtherTransferCount -ErrorAction SilentlyContinue))
    {
        $t[[int]$p.ProcessId] = $p
    }
    return $t
}

function Stop-Tree([int[]]$Ids)
{
    foreach ($id in $Ids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    if ($Ids.Count -gt 0) { Start-Sleep -Seconds 2 }
}

function Invoke-Monitored
{
    # Runs a command and watches its whole process tree. SYSTEM has no visible desktop, so an installer that waits for a
    # click simply sits there: the run counts as stuck when the tree (plus anything started since, such as the Windows
    # Installer service) has been idle for UiGraceSec while it owns a window, or for IdleSec without one.
    param
    (
        [string]$FilePath, [string]$Arguments, [string]$WorkingDirectory,
        [int]$TimeoutSec = 900, [int]$UiGraceSec = 30, [int]$IdleSec = 120,
        [switch]$CaptureText, [int]$StopAfterSec = 0
    )
    $stamp   = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $env:TEMP "probe-$stamp.out"
    $errFile = Join-Path $env:TEMP "probe-$stamp.err"
    $params  = @{ FilePath = $FilePath; PassThru = $true; RedirectStandardOutput = $outFile; RedirectStandardError = $errFile }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }
    if ("$Arguments".Trim()) { $params.ArgumentList = $Arguments }
    $started = Get-Date
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try
    {
        $p = Start-Process @params
        $null = $p.Handle   # cache the handle so ExitCode is still readable after the process exits
    }
    catch
    {
        return [pscustomobject]@{ ExitCode = $null; DurationSec = 0; WindowTitles = @(); Stuck = $null; TimedOut = $false; StdOut = ''; StdErr = "Could not start: $($_.Exception.Message)"; Text = ''; LeftRunning = @(); StartFailed = $true }
    }

    $rootId   = $p.Id
    $tree     = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$tree.Add($rootId)
    $prev     = @{}
    $idle     = 0.0
    $titles   = New-Object System.Collections.Generic.List[string]
    $texts    = New-Object System.Collections.Generic.List[string]
    $stuck    = $null
    $timedOut = $false
    $rootExit = $null
    $left     = @()
    $last     = 0.0
    $nextBeat = 30
    while ($true)
    {
        Start-Sleep -Milliseconds 2000
        $now = $sw.Elapsed.TotalSeconds
        $dt  = [Math]::Max(0.5, $now - $last)
        $last = $now
        $table = Get-ProcessTable

        # Grow the tree: anything started since the run began whose parent is in it (the parent may already be gone).
        do
        {
            $added = $false
            foreach ($kv in $table.GetEnumerator())
            {
                $id = [int]$kv.Key
                if (-not $tree.Contains($id) -and $tree.Contains([int]$kv.Value.ParentProcessId) -and $kv.Value.CreationDate -ge $started)
                {
                    [void]$tree.Add($id); $added = $true
                }
            }
        } while ($added)
        $alive = @($tree | Where-Object { $table.ContainsKey($_) })

        # Activity of the tree plus anything else started since the run began (msiexec service, TrustedInstaller ...).
        $cpu = 0.0; $io = 0.0
        foreach ($kv in $table.GetEnumerator())
        {
            $id = [int]$kv.Key
            $pr = $kv.Value
            if ($id -eq $PID -or $pr.Name -match '^(WmiPrvSE|conhost)\.exe$') { continue }
            if (-not ($tree.Contains($id) -or $pr.CreationDate -ge $started)) { continue }
            $c = [double]$pr.KernelModeTime + [double]$pr.UserModeTime
            $i = [double]$pr.ReadTransferCount + [double]$pr.WriteTransferCount + [double]$pr.OtherTransferCount
            if ($prev.ContainsKey($id)) { $cpu += [Math]::Max(0, $c - $prev[$id].Cpu); $io += [Math]::Max(0, $i - $prev[$id].Io) }
            else { $cpu += $c; $io += $i }
            $prev[$id] = @{ Cpu = $c; Io = $i }
        }
        $cpuMs  = $cpu / 10000.0
        $active = ($cpuMs -gt (25 * $dt)) -or ($io -gt (65536 * $dt))
        if ($active) { $idle = 0.0 } else { $idle += $dt }

        # Windows owned by the tree (helper windows filtered out). Only ones that look like they wait for a person count
        # towards "stuck"; WPF and Chromium-based UIs draw their controls themselves, so their class gives them away.
        $dialogs = New-Object System.Collections.Generic.List[string]
        $windows = New-Object System.Collections.Generic.List[string]
        foreach ($w in [ProbeWin]::TopWindows())
        {
            $parts = $w.Split('|', 4)
            if (-not $tree.Contains([int]$parts[0])) { continue }
            if ($IgnoredWindowClasses -contains $parts[2] -or $parts[3] -match $IgnoredWindowTitles) { continue }
            $shown = [ProbeWin]::Shown([int64]$parts[1])
            # A window showing a progress bar (/passive installs, chained redistributables) is not waiting for anyone.
            $progress = $shown -and [ProbeWin]::ShowsProgress([int64]$parts[1])
            $label = "$($parts[3]) [$($parts[2])$(if (-not $shown) { ', hidden' } elseif ($progress) { ', progress' })]"
            if (-not $titles.Contains($label)) { $titles.Add($label) }
            $windows.Add($parts[1])
            if ($shown -and -not $progress -and ([ProbeWin]::LooksInteractive([int64]$parts[1]) -or $parts[2] -match '^(HwndWrapper|Chrome_WidgetWin|#32770$)')) { $dialogs.Add($parts[1]) }
        }
        if ($CaptureText)
        {
            foreach ($h in $windows) { foreach ($t in [ProbeWin]::ChildTexts([int64]$h)) { if (-not $texts.Contains($t)) { $texts.Add($t) } } }
        }

        # A heartbeat for long installs, so the packager's log shows the run is alive and what it is doing.
        if ($StopAfterSec -eq 0 -and $now -ge $nextBeat)
        {
            $busy = @(@($alive | ForEach-Object { if ($table.ContainsKey($_)) { "$($table[$_].Name)" } }) +
                      @($table.Values | Where-Object { $_.CreationDate -ge $started -and $_.Name -match '^(msiexec|TiWorker|TrustedInstaller)\.exe$' } | ForEach-Object { "$($_.Name)" })) | Select-Object -Unique
            # What has actually landed on disk: the plainest sign of whether the install is moving.
            $files = "$([ProbeWin]::NewFilesSince([string[]]$ProgressRoots, [string[]]$ProgressSkip, $started.ToUniversalTime(), 1500))".Split('|')
            $written = $(if ([int64]$files[0] -gt 0) { "$($files[0])$(if ($files[2]) { '+' }) new files, latest $($files[1])" } else { 'no new files yet' })
            Write-ProbeLog ("Still running after {0}:{1:00} - {2}; {3}; {4}" -f [int][Math]::Floor($now / 60), [int]($now % 60), ($busy -join ', '), $(if ($active) { 'working' } else { "quiet for $([int]$idle)s" }), $written)
            $nextBeat += 30
        }

        $rootAlive = -not $p.HasExited
        if ($StopAfterSec -gt 0 -and ($now -ge $StopAfterSec -or ($dialogs.Count -gt 0 -and $idle -ge 4))) { break }
        if ($rootAlive)
        {
            if ($dialogs.Count -gt 0 -and $idle -ge $UiGraceSec)
            {
                # Say what the dialog shows (an error, a licence, a question), not just its title; buttons left out.
                $current = @($titles | Select-Object -Last 3) -join ' | '
                $said = @(foreach ($h in $dialogs) { [ProbeWin]::ShownChildTexts([int64]$h) }) | Where-Object { $_ -and $_.Trim().Length -gt 3 -and $_.Trim() -notmatch '^(?i)&?(OK|Cancel|Close|Yes|No|Next\s*>?|Install|Retry|Finish|Browse\.*|I Agree|Accept)$|^<\s*&?Back$' } | Select-Object -Unique
                $saidText = ((@($said) -join ' / ') -replace '\s+', ' ').Trim()
                if ($saidText.Length -gt 220) { $saidText = $saidText.Substring(0, 217) + '...' }
                $stuck = "waiting on a window ($current)$(if ($saidText) { ': "' + $saidText + '"' }) with no activity for $([int]$idle)s"
                break
            }
            if ($idle -ge $IdleSec) { $stuck = "no activity for $([int]$idle)s"; break }
        }
        else
        {
            if ($null -eq $rootExit) { $rootExit = $now }
            $others = @($alive | Where-Object { $_ -ne $rootId })
            if ($others.Count -eq 0) { break }
            # The installer exited but left children: wait while they work, but an app the installer launched at the end
            # (the program itself, a tray icon) must not hold the run forever.
            if ((-not $active -and ($now - $rootExit) -ge 10) -or ($now - $rootExit) -ge 300)
            {
                $left = @($others | ForEach-Object { if ($table.ContainsKey($_)) { "$($table[$_].Name)" } } | Select-Object -Unique)
                break
            }
        }
        if ($now -ge $TimeoutSec) { $timedOut = $true; break }
    }

    $remaining = @($tree | Where-Object { (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
    Stop-Tree $remaining
    [void]$p.WaitForExit(5000)
    $exit = $null
    if ($p.HasExited) { try { $exit = $p.ExitCode } catch { } }
    $so = ''; $se = ''
    try { if (Test-Path -LiteralPath $outFile) { $so = Get-Content -LiteralPath $outFile -Raw } } catch { }
    try { if (Test-Path -LiteralPath $errFile) { $se = Get-Content -LiteralPath $errFile -Raw } } catch { }
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        ExitCode     = $exit
        DurationSec  = [int]$sw.Elapsed.TotalSeconds
        WindowTitles = @($titles)
        Stuck        = $stuck
        TimedOut     = $timedOut
        StdOut       = "$so".Trim()
        StdErr       = "$se".Trim()
        Text         = ($texts -join "`n")
        LeftRunning  = @($left)
        StartFailed  = $false
    }
}

function Get-UninstallSnapshot
{
    $roots = @(
        @{ Hive = 'LocalMachine'; View = 'Registry64' },
        @{ Hive = 'LocalMachine'; View = 'Registry32' },
        @{ Hive = 'CurrentUser';  View = 'Default' }
    )
    $entries = @{}
    foreach ($r in $roots)
    {
        try
        {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$r.Hive, [Microsoft.Win32.RegistryView]$r.View)
            $key  = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $key) { continue }
            foreach ($name in $key.GetSubKeyNames())
            {
                $sub = $key.OpenSubKey($name)
                if (-not $sub) { continue }
                $id = "$($r.Hive)\$($r.View)\$name"
                # Windows adds this itself when it shims a setup program; it is not part of the app.
                if ([string]$sub.GetValue('DisplayName') -like 'Microsoft Windows Application Compatibility*') { $sub.Close(); continue }
                $entries[$id] = [pscustomobject]@{
                    Id                   = $id
                    KeyName              = $name
                    Location             = "$($r.Hive)\$($r.View)"
                    DisplayName          = [string]$sub.GetValue('DisplayName')
                    DisplayVersion       = [string]$sub.GetValue('DisplayVersion')
                    Publisher            = [string]$sub.GetValue('Publisher')
                    UninstallString      = [string]$sub.GetValue('UninstallString')
                    QuietUninstallString = [string]$sub.GetValue('QuietUninstallString')
                    InstallLocation      = [string]$sub.GetValue('InstallLocation')
                    DisplayIcon          = [string]$sub.GetValue('DisplayIcon')
                    SystemComponent      = [int]($sub.GetValue('SystemComponent', 0))
                    WindowsInstaller     = [int]($sub.GetValue('WindowsInstaller', 0))
                }
                $sub.Close()
            }
            $key.Close()
        }
        catch { }
    }
    return $entries
}

$SystemProfile = Join-Path $env:SystemRoot 'System32\config\systemprofile'

function Get-FootprintSnapshot
{
    # Names only - enough to diff before/after cheaply.
    $dirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $deep = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, (Join-Path $SystemProfile 'AppData\Local'), (Join-Path $SystemProfile 'AppData\Roaming'), (Join-Path $SystemProfile 'AppData\Local\Programs'))
    # .NET calls rather than Get-ChildItem/CIM throughout: the same data, and seconds faster in a freshly started sandbox.
    $subdirs = { param($p) try { [System.IO.Directory]::GetDirectories($p) } catch { @() } }
    foreach ($root in $deep)
    {
        if (-not $root -or -not [System.IO.Directory]::Exists($root)) { continue }
        foreach ($d in (& $subdirs $root))
        {
            [void]$dirs.Add($d)
            foreach ($d2 in (& $subdirs $d)) { [void]$dirs.Add($d2) }
        }
    }
    foreach ($d in (& $subdirs 'C:\')) { [void]$dirs.Add($d) }

    $links = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    foreach ($f in @(Get-ChildItem -LiteralPath $startMenu -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.lnk', '.url') })) { [void]$links.Add($f.FullName) }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $env:PUBLIC 'Desktop') -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' })) { [void]$links.Add($f.FullName) }

    $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in @('SOFTWARE', 'SOFTWARE\WOW6432Node'))
    {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($root)
        if (-not $k) { continue }
        foreach ($n in $k.GetSubKeyNames())
        {
            [void]$keys.Add("HKLM\$root\$n")
            if ($n -in @('Classes', 'WOW6432Node', 'Microsoft')) { continue }
            $sub = $k.OpenSubKey($n)
            if ($sub) { foreach ($n2 in $sub.GetSubKeyNames()) { [void]$keys.Add("HKLM\$root\$n\$n2") }; $sub.Close() }
        }
        $k.Close()
    }

    # Win32 services (own or shared process, as Win32_Service lists them; drivers left out), straight from the registry.
    $services = @{}
    $svcKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services')
    foreach ($n in $svcKey.GetSubKeyNames())
    {
        $s = $svcKey.OpenSubKey($n)
        if (-not $s) { continue }
        $type = $s.GetValue('Type')
        if ($type -is [int] -and ($type -band 0x30)) { $services[$n] = [pscustomobject]@{ Name = $n; DisplayName = [string]$s.GetValue('DisplayName'); PathName = [string]$s.GetValue('ImagePath') } }
        $s.Close()
    }
    $svcKey.Close()
    # Scheduled tasks are files under System32\Tasks named by their path ("\Vendor\Updater"); SYSTEM can read it.
    $tasks = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $taskRoot = Join-Path $env:SystemRoot 'System32\Tasks'
    try { foreach ($f in [System.IO.Directory]::GetFiles($taskRoot, '*', [System.IO.SearchOption]::AllDirectories)) { [void]$tasks.Add($f.Substring($taskRoot.Length)) } }
    catch { foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) { [void]$tasks.Add("$($t.TaskPath)$($t.TaskName)") } }
    return @{ Dirs = $dirs; Links = $links; Keys = $keys; Services = $services; Tasks = $tasks }
}

$NoiseDirs = '^(C:\\(Windows|Users|Work|Probe|Source|Config\.Msi|\$Recycle\.Bin|\$WinREAgent|System Volume Information|Recovery|PerfLogs|Program Files|Program Files \(x86\)|ProgramData)$)' +
    '|^C:\\ProgramData\\(Microsoft|Package Cache|regid\.[^\\]*|USOShared|USOPrivate|Packages|ssh|SoftwareDistribution)(\\|$)' +
    '|^C:\\Program Files( \(x86\))?\\(WindowsApps|ModifiableWindowsApps|Windows Defender[^\\]*|Windows Security|Microsoft Update Health Tools|Common Files\\microsoft shared)(\\|$)' +
    '|\\AppData\\(Local|Roaming)\\(Microsoft|Temp|Packages|ConnectedDevicesPlatform|D3DSCache|PeerDistRepub|AMD|ATI|NVIDIA|NVIDIA Corporation|Intel|IntelGraphicsProfiles)(\\|$)'
$NoiseKeys = '^HKLM\\SOFTWARE\\(WOW6432Node\\)?(Microsoft|Classes|Policies|RegisteredApplications|Clients|WOW6432Node|DefaultUserEnvironment|Intel)(\\|$)'

function Get-ExeInfo([string]$Path)
{
    $vi = $null
    try { $vi = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo } catch { }
    $ver = ''
    if ($vi) { $ver = '{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart; if ($ver -eq '0.0.0.0') { $ver = "$($vi.FileVersion)".Trim() } }
    $machine = ''
    try
    {
        $fs = [System.IO.File]::OpenRead($Path)
        try
        {
            $br = New-Object System.IO.BinaryReader($fs)
            if ($br.ReadUInt16() -eq 0x5A4D)
            {
                $fs.Position = 0x3C; $fs.Position = $br.ReadInt32()
                if ($br.ReadUInt32() -eq 0x00004550) { $machine = switch ([int]$br.ReadUInt16()) { 0x8664 { 'x64' } 0x014C { 'x86' } 0xAA64 { 'ARM64' } default { '' } } }
            }
        }
        finally { $fs.Dispose() }
    }
    catch { }
    return [ordered]@{
        Path            = $Path
        Machine         = $machine
        FileVersion     = $ver
        ProductVersion  = $(if ($vi) { "$($vi.ProductVersion)".Trim() } else { '' })
        ProductName     = $(if ($vi) { "$($vi.ProductName)".Trim() } else { '' })
        FileDescription = $(if ($vi) { "$($vi.FileDescription)".Trim() } else { '' })
        CompanyName     = $(if ($vi) { "$($vi.CompanyName)".Trim() } else { '' })
        Size            = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).Length
    }
}

function Compare-Footprint($Before, $After)
{
    # New folders: keep only the top-most new one of each branch, drop known noise.
    $newDirs = @($After.Dirs | Where-Object { -not $Before.Dirs.Contains($_) })
    $top = @($newDirs | Where-Object { $parent = Split-Path -Path $_ -Parent; -not ($newDirs -contains $parent) })
    $folders = New-Object System.Collections.Generic.List[object]
    $cache   = New-Object System.Collections.Generic.List[string]
    foreach ($d in ($top | Sort-Object))
    {
        if ($d -match '^C:\\ProgramData\\Package Cache\\') { $cache.Add($d); continue }
        if ($d -match $NoiseDirs) { continue }
        $exes = @(Get-ChildItem -LiteralPath $d -Recurse -Depth 4 -File -Filter '*.exe' -Force -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { Get-ExeInfo $_.FullName })
        $folders.Add([ordered]@{ Path = $d; PerUser = ($d -like "$SystemProfile\*"); Exes = $exes })
    }
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }
    $links = @($After.Links | Where-Object { -not $Before.Links.Contains($_) } | ForEach-Object {
        $target = ''; $lnkArgs = ''
        if ($shell -and $_ -like '*.lnk') { try { $s = $shell.CreateShortcut($_); $target = $s.TargetPath; $lnkArgs = $s.Arguments } catch { } }
        [ordered]@{ Path = $_; Target = $target; Arguments = $lnkArgs }
    })
    $newKeys = @($After.Keys | Where-Object { -not $Before.Keys.Contains($_) })
    $keys = @($newKeys | Where-Object { $parent = $_.Substring(0, $_.LastIndexOf('\')); -not ($newKeys -contains $parent) -and $_ -notmatch $NoiseKeys } | Sort-Object)
    $services = @($After.Services.Keys | Where-Object { -not $Before.Services.ContainsKey($_) } | ForEach-Object { $s = $After.Services[$_]; [ordered]@{ Name = $s.Name; DisplayName = $s.DisplayName; PathName = $s.PathName } })
    $tasks = @($After.Tasks | Where-Object { -not $Before.Tasks.Contains($_) -and $_ -notlike '\Microsoft\*' } | Sort-Object)
    return [ordered]@{
        Folders      = $folders.ToArray()
        Shortcuts    = $links
        RegistryKeys = $keys
        Services     = $services
        Tasks        = $tasks
        PackageCache = $cache.ToArray()
        PerUser      = @($folders | Where-Object { $_.PerUser -and @($_.Exes).Count -gt 0 } | ForEach-Object { $_.Path })
    }
}

function Test-FootprintEmpty($Fp)
{
    return (@($Fp.Folders).Count + @($Fp.Shortcuts).Count + @($Fp.RegistryKeys).Count + @($Fp.Services).Count + @($Fp.Tasks).Count) -eq 0
}

function Split-CommandLine([string]$Command)
{
    # "C:\path\unins000.exe" /SILENT   |   C:\path\uninstall.exe --silent   |   MsiExec.exe /X{GUID}
    $c = "$Command".Trim()
    if ($c -match '^"([^"]+)"\s*(.*)$') { return @{ File = $Matches[1]; Args = $Matches[2].Trim() } }
    $m = [regex]::Match($c, '^(.+?\.exe)\s*(.*)$', 'IgnoreCase')
    if ($m.Success) { return @{ File = $m.Groups[1].Value.Trim(); Args = $m.Groups[2].Value.Trim() } }
    $parts = $c -split '\s+', 2
    return @{ File = $parts[0]; Args = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }) }
}

function Invoke-Detection([string]$ScriptPath)
{
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath 2>&1
    $code = $LASTEXITCODE
    $text = (@($out) -join ' ').Trim()
    return [ordered]@{ ExitCode = $code; Output = $text; Detected = ($code -eq 0 -and [bool]$text) }
}

function Select-Entry($Entries, [string]$Hint)
{
    # The uninstall entry that best represents the app (installers sometimes add runtimes alongside).
    $visible = @($Entries | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 })
    if ($visible.Count -eq 0) { return $null }
    if ($visible.Count -eq 1 -or -not $Hint) { return $visible[0] }
    $h = $Hint.ToLowerInvariant()
    $best = $null; $bestScore = -1
    foreach ($e in $visible)
    {
        $n = $e.DisplayName.ToLowerInvariant()
        $score = 0
        if ($n -eq $h) { $score += 4 } elseif ($n.StartsWith($h)) { $score += 3 } elseif ($n.Contains($h)) { $score += 2 } elseif ($h.Contains($n)) { $score += 1 }
        if ($e.QuietUninstallString) { $score += 0.5 }
        if ($score -gt $bestScore) { $best = $e; $bestScore = $score }
    }
    return $best
}

function Copy-Input($Cfg)
{
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    # Strings only: an empty list can arrive as {} from Windows PowerShell 5.1's ConvertTo-Json.
    $items = @($Cfg.CopyItems | Where-Object { $_ -is [string] -and $_ })
    if ($items.Count -eq 0) { Copy-Item -Path (Join-Path $srcDir '*') -Destination $workDir -Recurse -Force -ErrorAction Stop }
    foreach ($rel in $items)
    {
        $from = Join-Path $srcDir $rel
        $to   = Join-Path $workDir $rel
        $parent = Split-Path -Path $to -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $from -Destination $to -Recurse -Force -ErrorAction Stop
    }
    $n = @(Get-ChildItem -LiteralPath $workDir -Recurse -Force -File -ErrorAction SilentlyContinue).Count
    Write-ProbeLog "Copied the input to $workDir ($n files)"
    if ($n -eq 0) { throw "Nothing could be copied from $srcDir (the folder shared from the packaging PC): the sandbox sees it as empty." }
}

function Invoke-InstallMode($Cfg)
{
    if ($Cfg.FilePath -match '(?i)\\(cscript|wscript)\.exe$' -and -not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\vbscript.dll')))
    {
        throw 'VBScript is not available in this Windows Sandbox: the engine is an optional Windows component that Microsoft is retiring, and the sandbox image does not include it. The script could not be run here.'
    }
    Copy-Input $Cfg
    Write-ProbeLog "Command: `"$($Cfg.FilePath)`" $($Cfg.Arguments)"
    $beforeEntries = Get-UninstallSnapshot
    $beforeFp      = Get-FootprintSnapshot
    Write-ProbeLog "Baseline: $($beforeEntries.Count) uninstall entries, $($beforeFp.Dirs.Count) folders, $($beforeFp.Services.Count) services"

    $inst = Invoke-Monitored -FilePath $Cfg.FilePath -Arguments $Cfg.Arguments -WorkingDirectory $Cfg.WorkingDirectory -TimeoutSec $Cfg.TimeoutSec -UiGraceSec $Cfg.UiGraceSec -IdleSec $Cfg.IdleSec
    $result.Install = $inst
    Write-ProbeLog "Install finished: exit $($inst.ExitCode), $($inst.DurationSec)s$(if ($inst.Stuck) { ", STUCK: $($inst.Stuck)" })$(if ($inst.TimedOut) { ', TIMED OUT' })"
    if (@($inst.WindowTitles).Count -gt 0) { Write-ProbeLog "Windows seen: $(@($inst.WindowTitles) -join ' | ')" }
    if (@($inst.LeftRunning).Count -gt 0) { Write-ProbeLog "Left running after the installer exited (stopped): $(@($inst.LeftRunning) -join ', ')" }

    Start-Sleep -Seconds 3
    $afterEntries = Get-UninstallSnapshot
    $new = @($afterEntries.Keys | Where-Object { -not $beforeEntries.ContainsKey($_) } | ForEach-Object { $afterEntries[$_] } | Where-Object { $_.DisplayName })
    $result.NewEntries = $new
    $primary = Select-Entry $new $Cfg.AppNameHint
    $result.PrimaryEntry = $primary
    Write-ProbeLog "New uninstall entries: $($new.Count)$(if ($new.Count) { ' - ' + (($new | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)$(if ($_.SystemComponent -eq 1) { ' (hidden)' })" }) -join ' | ') })"

    $fp = Compare-Footprint $beforeFp (Get-FootprintSnapshot)
    $result.Footprint = $fp
    Write-ProbeLog "Footprint: $(@($fp.Folders).Count) folders, $(@($fp.Shortcuts).Count) shortcuts, $(@($fp.RegistryKeys).Count) registry keys, $(@($fp.Services).Count) services, $(@($fp.Tasks).Count) tasks$(if (@($fp.PerUser).Count) { ', PER-USER: ' + (@($fp.PerUser) -join ', ') })"
    foreach ($f in @($fp.Folders)) { Write-ProbeLog "  folder $($f.Path) ($(@($f.Exes).Count) exe)" }

    $detPath = $null
    if ($Cfg.DetectionScriptBase64)
    {
        $detPath = Join-Path $workDir 'Detect-Probe.ps1'
        [System.IO.File]::WriteAllBytes($detPath, [Convert]::FromBase64String($Cfg.DetectionScriptBase64))
        $result.Detection = Invoke-Detection $detPath
        Write-ProbeLog "Detection script: exit $($result.Detection.ExitCode) $($result.Detection.Output)"
    }

    $silent   = -not $inst.Stuck -and -not $inst.TimedOut -and -not $inst.StartFailed
    $exitOk   = $null -ne $inst.ExitCode -and (@($Cfg.SuccessCodes) -contains [int]$inst.ExitCode)
    $evidence = ($null -ne $primary) -or -not (Test-FootprintEmpty $fp) -or ($result.Detection -and $result.Detection.Detected)
    $result.InstallSucceeded = $silent -and $exitOk -and $evidence
    Write-ProbeLog "Silent: $silent, exit OK: $exitOk, evidence of install: $evidence => succeeded: $($result.InstallSucceeded)"

    # What the installer says about its own switches, for the report. Only needed when this switch set did not work.
    if (-not $result.InstallSucceeded -and $Cfg.Help -and $Cfg.Help.FilePath)
    {
        Write-ProbeLog "Help probe: $($Cfg.Help.Arguments)"
        $h = Invoke-Monitored -FilePath $Cfg.Help.FilePath -Arguments $Cfg.Help.Arguments -WorkingDirectory $Cfg.WorkingDirectory -TimeoutSec 30 -StopAfterSec 20 -CaptureText
        $text = (@($h.StdOut, $h.StdErr, $h.Text) | Where-Object { $_ }) -join "`n"
        $result.Help = [ordered]@{ Switch = "$($Cfg.Help.Arguments)"; Text = $text; WindowTitles = @($h.WindowTitles); ExitCode = $h.ExitCode }
        Write-ProbeLog "Help probe captured $($text.Length) chars, windows: $(@($h.WindowTitles) -join ' | ')"
    }

    # Prove the registered uninstall while there is a machine with the app on it.
    if ($result.InstallSucceeded -and $primary -and ($primary.QuietUninstallString -or $primary.UninstallString))
    {
        $fromQuiet = [bool]$primary.QuietUninstallString
        $cmd   = if ($fromQuiet) { $primary.QuietUninstallString } else { $primary.UninstallString }
        $parts = Split-CommandLine $cmd
        $file  = $parts.File
        $uArgs = $parts.Args
        if ($file -match '(?i)msiexec')
        {
            $uArgs = ($uArgs -replace '(?i)/I\s*\{', '/X{')
            if ($uArgs -notmatch '(?i)/q') { $uArgs = "$uArgs /qn /norestart".Trim() }
        }
        elseif (-not $fromQuiet -and "$($Cfg.UninstallArgs)".Trim())
        {
            $uArgs = "$uArgs $($Cfg.UninstallArgs)".Trim()
        }
        # A bare name is either a system tool on PATH (powershell.exe, cmd.exe, rundll32.exe) or a file in the install folder.
        if ($file -notmatch '\\' -and $file -notmatch '(?i)msiexec' -and $primary.InstallLocation -and -not (Get-Command -Name $file -CommandType Application -ErrorAction SilentlyContinue))
        {
            $file = Join-Path $primary.InstallLocation $file
        }
        Write-ProbeLog "Uninstall: `"$file`" $uArgs  (from $(if ($fromQuiet) { 'QuietUninstallString' } else { 'UninstallString' }))"
        $un = Invoke-Monitored -FilePath $file -Arguments $uArgs -TimeoutSec $Cfg.TimeoutSec -UiGraceSec $Cfg.UiGraceSec -IdleSec $Cfg.IdleSec
        Start-Sleep -Seconds 3
        $final = Get-UninstallSnapshot
        $gone  = -not $final.ContainsKey($primary.Id)
        $detAfter = $null
        if ($detPath) { $detAfter = Invoke-Detection $detPath }
        $result.Uninstall = [ordered]@{
            File = $file; Arguments = $uArgs; FromQuietUninstallString = $fromQuiet
            ExitCode = $un.ExitCode; DurationSec = $un.DurationSec; Stuck = $un.Stuck; TimedOut = $un.TimedOut
            WindowTitles = @($un.WindowTitles); EntryRemoved = $gone; DetectionAfter = $detAfter
            Verified = ($gone -and -not $un.Stuck -and -not $un.TimedOut -and -not ($detAfter -and $detAfter.Detected))
        }
        Write-ProbeLog "Uninstall finished: exit $($un.ExitCode), $($un.DurationSec)s, entry removed: $gone$(if ($un.Stuck) { ", STUCK: $($un.Stuck)" })$(if ($detAfter) { ", detected afterwards: $($detAfter.Detected)" })"
    }
}

function Invoke-ValidateMode($Cfg)
{
    Copy-Input $Cfg
    $pkgDir = Join-Path $workDir 'Package'
    $exe    = Join-Path $pkgDir 'Invoke-AppDeployToolkit.exe'
    $detect = Join-Path $workDir $Cfg.DetectScriptName
    if (-not (Test-Path -LiteralPath $exe)) { throw "Invoke-AppDeployToolkit.exe not found in $pkgDir" }
    $beforeEntries = Get-UninstallSnapshot
    $beforeFp      = Get-FootprintSnapshot
    $v = [ordered]@{ Install = $null; DetectAfterInstall = $null; InstalledFootprint = $null; Uninstall = $null; DetectAfterUninstall = $null; Leftovers = $null; Passed = $false }

    Write-ProbeLog "Package install: Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode $($Cfg.DeployMode)"
    $i = Invoke-Monitored -FilePath $exe -Arguments "-DeploymentType Install -DeployMode $($Cfg.DeployMode)" -WorkingDirectory $pkgDir -TimeoutSec $Cfg.TimeoutSec -UiGraceSec $Cfg.UiGraceSec -IdleSec $Cfg.IdleSec
    $v.Install = $i
    Write-ProbeLog "Install finished: exit $($i.ExitCode), $($i.DurationSec)s$(if ($i.Stuck) { ", STUCK: $($i.Stuck)" })$(if ($i.TimedOut) { ', TIMED OUT' })"
    Start-Sleep -Seconds 3
    $v.DetectAfterInstall = Invoke-Detection $detect
    Write-ProbeLog "Detection after install: exit $($v.DetectAfterInstall.ExitCode) $($v.DetectAfterInstall.Output)"
    $afterEntries = Get-UninstallSnapshot
    $v.InstalledFootprint = Compare-Footprint $beforeFp (Get-FootprintSnapshot)
    $v.InstalledEntries = @($afterEntries.Keys | Where-Object { -not $beforeEntries.ContainsKey($_) } | ForEach-Object { $afterEntries[$_] } | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 } | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)".Trim() })

    Write-ProbeLog "Package uninstall: Invoke-AppDeployToolkit.exe -DeploymentType Uninstall -DeployMode $($Cfg.DeployMode)"
    $u = Invoke-Monitored -FilePath $exe -Arguments "-DeploymentType Uninstall -DeployMode $($Cfg.DeployMode)" -WorkingDirectory $pkgDir -TimeoutSec $Cfg.TimeoutSec -UiGraceSec $Cfg.UiGraceSec -IdleSec $Cfg.IdleSec
    $v.Uninstall = $u
    Write-ProbeLog "Uninstall finished: exit $($u.ExitCode), $($u.DurationSec)s$(if ($u.Stuck) { ", STUCK: $($u.Stuck)" })$(if ($u.TimedOut) { ', TIMED OUT' })"
    Start-Sleep -Seconds 3
    $v.DetectAfterUninstall = Invoke-Detection $detect
    Write-ProbeLog "Detection after uninstall: exit $($v.DetectAfterUninstall.ExitCode) $($v.DetectAfterUninstall.Output)"

    $finalEntries = Get-UninstallSnapshot
    $left = Compare-Footprint $beforeFp (Get-FootprintSnapshot)
    $left.Entries = @($finalEntries.Keys | Where-Object { -not $beforeEntries.ContainsKey($_) } | ForEach-Object { $finalEntries[$_] } | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 } | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)".Trim() })
    $v.Leftovers = $left

    $codes = @($Cfg.SuccessCodes)
    $installOk   = -not $i.Stuck -and -not $i.TimedOut -and $null -ne $i.ExitCode -and ($codes -contains [int]$i.ExitCode)
    $uninstallOk = -not $u.Stuck -and -not $u.TimedOut -and $null -ne $u.ExitCode -and ($codes -contains [int]$u.ExitCode)
    $v.InstallOk   = $installOk
    $v.UninstallOk = $uninstallOk
    $v.Passed = $installOk -and $v.DetectAfterInstall.Detected -and $uninstallOk -and -not $v.DetectAfterUninstall.Detected
    Write-ProbeLog "Validation: install OK $installOk, detected $($v.DetectAfterInstall.Detected), uninstall OK $uninstallOk, detected after uninstall $($v.DetectAfterUninstall.Detected) => passed: $($v.Passed)"
    $result.Validation = $v

    $logs = Join-Path $probeDir 'logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    Copy-Item -Path (Join-Path $env:SystemRoot 'Logs\Software\*') -Destination $logs -Recurse -Force -ErrorAction SilentlyContinue
}

function Disable-SmartAppControl
{
    # Windows Sandbox starts with Smart App Control in evaluation mode but Microsoft Defender's engine disabled. Every MSI
    # install then asks Defender about the package (msiexec -> wldp -> MpClient -> Defender's RPC endpoint), gets no
    # answer and retries with backoff for 120 s before carrying on (traced with ETW). Real devices either run Defender,
    # which answers at once, or have Smart App Control off (managed devices), so it is switched off here.
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
    $state = (Get-ItemProperty -LiteralPath $key -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
    if ($null -eq $state -or $state -eq 0) { return }
    try
    {
        Set-ItemProperty -LiteralPath $key -Name VerifiedAndReputablePolicyState -Value 0 -Type DWord -ErrorAction Stop
        $ciTool = Join-Path $env:SystemRoot 'System32\CiTool.exe'
        if (Test-Path -LiteralPath $ciTool) { [void](cmd.exe /c "`"$ciTool`" --refresh < NUL 2>&1") }
        Write-ProbeLog "Smart App Control switched off in the sandbox (was $state): Defender does not run here, so each MSI would wait 2 minutes for it."
    }
    catch
    {
        Write-ProbeLog "Could not switch off Smart App Control ($($_.Exception.Message)); each MSI may pause for 2 minutes."
    }
}

try
{
    $cfg = Get-Content -LiteralPath (Join-Path $probeDir 'config.json') -Raw | ConvertFrom-Json
    $result.Mode  = "$($cfg.Mode)"
    $result.Label = "$($cfg.Label)"
    Write-ProbeLog "Probe started as $(whoami) - mode $($cfg.Mode)$(if ($cfg.Label) { ": $($cfg.Label)" })"
    Disable-SmartAppControl
    if ($cfg.Mode -eq 'Validate') { Invoke-ValidateMode $cfg } else { Invoke-InstallMode $cfg }
}
catch
{
    $result.Error = $_.Exception.Message
    Write-ProbeLog "ERROR: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)"
}
finally
{
    $result.Finished = (Get-Date).ToString('s')
    $json = $result | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($resultPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-ProbeLog 'Result written.'
}
'@

function Get-WsbPath
{
    # The Windows Sandbox CLI ships with the Store-serviced Windows Sandbox (Windows 11 24H2 and later) as an app
    # execution alias, which is not always on PATH for the process that starts us, and not always registered for
    # every user; the copy in the app's own folder runs just as well. PSADT_PACKAGER_SANDBOX=Classic ignores it.
    if ($env:PSADT_PACKAGER_SANDBOX -eq 'Classic') { return $null }
    if ($script:WsbPath -and (Test-Path -LiteralPath $script:WsbPath)) { return $script:WsbPath }
    $found = $null
    $cmd = Get-Command -Name 'wsb.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $found = $cmd.Source }
    if (-not $found)
    {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wsb.exe'
        if (Test-Path -LiteralPath $alias) { $found = $alias }
    }
    if (-not $found)
    {
        $pkg = $null
        try { $pkg = Get-AppxPackage -Name 'MicrosoftWindows.WindowsSandbox' -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1 } catch { }
        if ($pkg -and $pkg.InstallLocation)
        {
            $exe = Join-Path $pkg.InstallLocation 'wsb.exe'
            if (Test-Path -LiteralPath $exe) { $found = $exe }
        }
    }
    $script:WsbPath = $found
    return $found
}

function Test-WindowsSandbox
{
    # Returns how sandbox runs are driven - 'Cli' (wsb.exe) or 'Classic' (a .wsb file in a Sandbox window, for the
    # built-in Windows Sandbox that has not been updated from the Microsoft Store) - or $null with the reason logged.
    if (Get-WsbPath) { $script:SandboxMode = 'Cli'; return 'Cli' }
    if (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'))
    {
        if ($script:SandboxMode -ne 'Classic')
        {
            Write-PackagerLog 'This Windows Sandbox has no command-line tool (wsb.exe comes with the Microsoft Store update of Windows Sandbox), so each sandbox run starts Windows Sandbox with its window hidden; it runs on its own and closes itself when the run is done.'
        }
        $script:SandboxMode = 'Classic'
        return 'Classic'
    }
    $script:SandboxMode = $null
    Write-PackagerLog 'Windows Sandbox is not installed. Enable it in Windows Features (or Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM from Windows PowerShell 5.1 as admin) and reboot.' -Level Warn
    return $null
}

function ConvertTo-CommandLineArgument
{
    # Quotes one argument the way CommandLineToArgvW / .NET expect (wsb.exe is a .NET app).
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    if ($Text -and $Text -notmatch '[\s"]') { return $Text }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Text.ToCharArray())
    {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\' * ($slashes * 2 + 1)); [void]$sb.Append('"') }
        else { if ($slashes) { [void]$sb.Append('\' * $slashes) }; [void]$sb.Append($ch) }
        $slashes = 0
    }
    if ($slashes) { [void]$sb.Append('\' * ($slashes * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-Wsb
{
    # Runs wsb.exe and returns its exit code and output. Keeps the GUI responsive and calls OnTick while waiting.
    param([Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSec = 120, [scriptblock]$OnTick)
    $wsb = Get-WsbPath
    if (-not $wsb) { throw 'wsb.exe (Windows Sandbox CLI) was not found.' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $wsb
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-CommandLineArgument $_ })) -join ' '
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    while (-not $p.WaitForExit(500))
    {
        Invoke-UiRefresh
        if ($OnTick) { & $OnTick }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { $timedOut = $true; try { $p.Kill() } catch { }; break }
    }
    [void]$p.WaitForExit(5000)
    $text = ("$($outTask.Result)`n$($errTask.Result)").Trim()
    $code = $null
    if (-not $timedOut) { $code = $p.ExitCode }
    return [pscustomobject]@{ ExitCode = $code; Output = $text; TimedOut = $timedOut }
}

function Get-RunningSandboxIds
{
    $r = Invoke-Wsb -Arguments @('list') -TimeoutSec 30
    return @([regex]::Matches("$($r.Output)", '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value })
}

function Start-PackagerSandbox
{
    # Starts a headless sandbox (no window) with the given folders mapped; returns its id.
    param([Parameter(Mandatory)][object[]]$MappedFolders, [bool]$Network = $true)
    $ours = Join-Path $script:AppDataDir 'Sandbox\running.txt'
    $running = @(Get-RunningSandboxIds)
    if ($running.Count -gt 0)
    {
        # running.txt lists the sandboxes the packager started as "id|owner process id". One whose owner has exited
        # (packager closed mid-run) is left over and can go; one whose owner is still running belongs to another
        # packager window; anything not listed belongs to the user.
        $known = @{}
        if (Test-Path -LiteralPath $ours)
        {
            foreach ($line in @(Get-Content -LiteralPath $ours -ErrorAction SilentlyContinue | Where-Object { $_ }))
            {
                $parts = $line.Split('|')
                $owner = 0
                if ($parts.Count -gt 1) { [void][int]::TryParse($parts[1], [ref]$owner) }
                $known[$parts[0]] = $owner
            }
        }
        foreach ($id in $running)
        {
            if (-not $known.ContainsKey($id)) { throw 'A Windows Sandbox is already running. Only one can run at a time - close it and try again.' }
            $owner = $known[$id]
            if ($owner -and $owner -ne $PID -and (Get-Process -Id $owner -ErrorAction SilentlyContinue))
            {
                throw 'Another PSADT Packager window is using Windows Sandbox right now, and only one sandbox can run at a time. Wait for it to finish and try again.'
            }
            Write-PackagerLog "Stopping a sandbox left over from an earlier run ($id)"
            [void](Invoke-Wsb -Arguments @('stop', '--id', $id) -TimeoutSec 60)
        }
    }
    $esc = { param($t) [System.Security.SecurityElement]::Escape("$t") }
    $xml = '<Configuration><MappedFolders>'
    foreach ($m in $MappedFolders)
    {
        $xml += '<MappedFolder><HostFolder>' + (& $esc $m.Host) + '</HostFolder><SandboxFolder>' + (& $esc $m.Sandbox) + '</SandboxFolder><ReadOnly>' + $(if ($m.ReadOnly) { 'true' } else { 'false' }) + '</ReadOnly></MappedFolder>'
    }
    $xml += '</MappedFolders><Networking>' + $(if ($Network) { 'Default' } else { 'Disable' }) + '</Networking></Configuration>'
    $r = Invoke-Wsb -Arguments @('start', '--config', $xml, '--raw') -TimeoutSec 180
    $id = $null
    try { $id = "$(($r.Output | ConvertFrom-Json).Id)" } catch { }
    if (-not $id) { $id = ([regex]::Match("$($r.Output)", '[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}')).Value }
    if (-not $id) { throw "Windows Sandbox did not start: $($r.Output)" }
    $dir = Split-Path -Path $ours -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -LiteralPath $ours -Value "$id|$PID"
    return $id
}

function Stop-PackagerSandbox
{
    param([string]$Id)
    if (-not $Id) { return }
    [void](Invoke-Wsb -Arguments @('stop', '--id', $Id) -TimeoutSec 90)
    $ours = Join-Path $script:AppDataDir 'Sandbox\running.txt'
    if (Test-Path -LiteralPath $ours)
    {
        $keep = @(Get-Content -LiteralPath $ours -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Split('|')[0] -ne $Id })
        Set-Content -LiteralPath $ours -Value $keep
    }
}

$script:ClassicSandboxBootstrap = @'
# Logon command of a classic Windows Sandbox run (runs as WDAGUtilityAccount, an administrator). Starts Run-Probe.ps1 as
# SYSTEM through a scheduled task, as "wsb exec -r System" does, waits for it, records the outcome and shuts the sandbox
# down, which closes its window.
$done = 'C:\Probe\classic-done.txt'
$outcome = ''
try
{
    $ps       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action   = New-ScheduledTaskAction -Execute $ps -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\Probe\Run-Probe.ps1'
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName 'PsadtPackagerProbe' -Action $action -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName 'PsadtPackagerProbe' -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-ScheduledTask -TaskName 'PsadtPackagerProbe').State -ne 'Running' -and -not (Test-Path -LiteralPath 'C:\Probe\probe.log') -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    while ((Get-ScheduledTask -TaskName 'PsadtPackagerProbe').State -eq 'Running') { Start-Sleep -Seconds 2 }
    $outcome = 'exit ' + (Get-ScheduledTaskInfo -TaskName 'PsadtPackagerProbe').LastTaskResult
}
catch
{
    $outcome = 'error ' + $_.Exception.Message
}
finally
{
    [System.IO.File]::WriteAllText($done, $outcome)
    & shutdown.exe /s /t 0 /f
}
'@

function Hide-SandboxWindows
{
    # Hides every visible top-level window of the given processes (no taskbar button either). The Sandbox window only
    # shows the sandbox's desktop; the run inside goes on as SYSTEM whether or not anyone can see it.
    param([int[]]$ProcessIds)
    if (-not $ProcessIds) { return 0 }
    if (-not ('PsadtPackager.SandboxWindows' -as [type]))
    {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace PsadtPackager
{
    public static class SandboxWindows
    {
        private delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd, int cmd);
        public static int Hide(int[] processIds)
        {
            var ids = new HashSet<uint>();
            foreach (int id in processIds) { ids.Add((uint)id); }
            int hidden = 0;
            EnumWindows(delegate (IntPtr hwnd, IntPtr lParam)
            {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                if (ids.Contains(pid) && IsWindowVisible(hwnd)) { ShowWindow(hwnd, 0); hidden++; }
                return true;
            }, IntPtr.Zero);
            return hidden;
        }
    }
}
'@
    }
    return [PsadtPackager.SandboxWindows]::Hide($ProcessIds)
}

function Invoke-ClassicSandboxRun
{
    # For a Windows Sandbox without wsb.exe (the built-in one on Windows 11 24H2 until it is updated from the Microsoft
    # Store, which managed PCs often block): runs a .wsb file in a Sandbox window. Its logon command runs Run-Probe.ps1
    # as SYSTEM and shuts the sandbox down when it is done. Only one sandbox can run at a time, so one already open stops us.
    param
    (
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][object[]]$MappedFolders,
        [int]$TimeoutSec = 1800,
        [bool]$Network = $true,
        [scriptblock]$OnTick
    )
    $names = @('WindowsSandbox', 'WindowsSandboxClient', 'WindowsSandboxRemoteSession')
    # running.txt notes "classic|owner process id" while a run is under way, so a hidden sandbox left behind by a packager
    # that was closed mid-run can be told apart from one the user opened (or another packager window is using).
    $ours = Join-Path $script:AppDataDir 'Sandbox\running.txt'
    $classicLines = @(Get-Content -LiteralPath $ours -ErrorAction SilentlyContinue | Where-Object { $_ -like 'classic|*' })
    if (Get-Process -Name $names -ErrorAction SilentlyContinue)
    {
        $orphan = $false
        foreach ($line in $classicLines)
        {
            $owner = 0
            [void][int]::TryParse($line.Split('|')[1], [ref]$owner)
            if ($owner -and $owner -ne $PID -and (Get-Process -Id $owner -ErrorAction SilentlyContinue))
            {
                throw 'Another PSADT Packager window is using Windows Sandbox right now, and only one sandbox can run at a time. Wait for it to finish and try again.'
            }
            $orphan = $true
        }
        if (-not $orphan) { throw 'Windows Sandbox is already open. Only one sandbox can run at a time - close it and try again.' }
        Write-PackagerLog 'Closing a Windows Sandbox left over from an interrupted run.'
        Get-Process -Name $names -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $pause = [System.Diagnostics.Stopwatch]::StartNew()
        while ($pause.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 250; Invoke-UiRefresh }
    }
    $keep = @(Get-Content -LiteralPath $ours -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notlike 'classic|*' })
    New-Item -ItemType Directory -Path (Split-Path -Path $ours -Parent) -Force | Out-Null
    Set-Content -LiteralPath $ours -Value (@($keep) + "classic|$PID")
    $done = Join-Path $RunDir 'classic-done.txt'
    if (Test-Path -LiteralPath $done) { Remove-Item -LiteralPath $done -Force }
    Write-Utf8File -Path (Join-Path $RunDir 'Start-Classic.ps1') -Content $script:ClassicSandboxBootstrap
    $esc = { param($t) [System.Security.SecurityElement]::Escape("$t") }
    $xml = '<Configuration><Networking>' + $(if ($Network) { 'Default' } else { 'Disable' }) + '</Networking><MappedFolders>'
    foreach ($m in $MappedFolders)
    {
        $xml += '<MappedFolder><HostFolder>' + (& $esc $m.Host) + '</HostFolder><SandboxFolder>' + (& $esc $m.Sandbox) + '</SandboxFolder><ReadOnly>' + $(if ($m.ReadOnly) { 'true' } else { 'false' }) + '</ReadOnly></MappedFolder>'
    }
    $xml += '</MappedFolders><LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Probe\Start-Classic.ps1</Command></LogonCommand></Configuration>'
    $wsbFile = Join-Path $RunDir 'PsadtPackager.wsb'
    Write-Utf8File -Path $wsbFile -Content $xml
    $logPath = Join-Path $RunDir 'probe.log'
    $startLimit = 180   # seconds for the sandbox to boot, sign in and start the probe; normally 15-60

    # Opening a sandbox right after another has closed sometimes fails ("Windows Sandbox failed to initialize"), and the
    # error window stays open. So: if the probe has not started within $startLimit, close everything and try once more.
    # The window is hidden as soon as it appears (PSADT_PACKAGER_SANDBOX_WINDOW=Show keeps it), except on that second
    # try, so whatever stopped the first one is on screen.
    for ($try = 1; $try -le 2; $try++)
    {
        $hide = $try -eq 1 -and $env:PSADT_PACKAGER_SANDBOX_WINDOW -ne 'Show'
        if ($try -eq 1 -and $hide) { Write-PackagerLog 'Starting Windows Sandbox for this run. Its window is kept hidden and closes itself when the run is done.' }
        elseif ($try -eq 1) { Write-PackagerLog 'Opening a Windows Sandbox window for this run (it closes itself when the run is done).' }
        else { Write-PackagerLog 'Windows Sandbox did not start the run; closing it and trying once more with its window shown.' -Level Warn }
        $style = $(if ($hide) { 'Hidden' } else { 'Normal' })
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe') -ArgumentList ('"' + $wsbFile + '"') -WindowStyle $style | Out-Null

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastCheck = 0
        $seen = $false
        $state = $null
        $outcome = $null
        while (-not $state)
        {
            # Look for the window every 50 ms while the sandbox starts (it appears then), every 250 ms after that.
            $step = $(if ($hide -and $sw.Elapsed.TotalSeconds -lt 90) { 50 } else { 250 })
            for ($k = 0; $k -lt (1000 / $step); $k++)
            {
                Start-Sleep -Milliseconds $step
                if ($hide) { [void](Hide-SandboxWindows -ProcessIds @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })) }
                if ($k % 5 -eq 0) { Invoke-UiRefresh }
            }
            if ($OnTick) { & $OnTick }
            $started = Test-Path -LiteralPath $logPath
            if (Test-Path -LiteralPath $done) { $outcome = "$(Get-Content -LiteralPath $done -Raw -ErrorAction SilentlyContinue)".Trim(); $state = 'Done' }
            elseif (-not $started -and $sw.Elapsed.TotalSeconds -ge $startLimit) { $state = 'NoStart' }
            elseif ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { $state = 'TimedOut' }
            elseif ($sw.Elapsed.TotalSeconds - $lastCheck -ge 5)
            {
                # The window takes a moment to appear; once it has, its disappearance means the run was cut short.
                $lastCheck = $sw.Elapsed.TotalSeconds
                if (Get-Process -Name $names -ErrorAction SilentlyContinue) { $seen = $true }
                elseif ($seen) { $state = $(if ($started) { 'Closed' } else { 'NoStart' }) }
            }
        }
        if ($state -eq 'TimedOut') { Write-PackagerLog "The sandbox run did not finish within $([int]($TimeoutSec / 60)) minutes; closing it." -Level Warn }
        if ($state -eq 'Closed') { Write-PackagerLog 'The Windows Sandbox window closed before the run finished.' -Level Warn }
        if ($outcome -and $outcome -ne 'exit 0') { Write-PackagerLog "Sandbox logon command: $outcome" -Level Warn }

        # After a finished run the sandbox shuts itself down; give it time, then close whatever is left.
        $wait = [System.Diagnostics.Stopwatch]::StartNew()
        # Windows Sandbox shows a small status window while it shuts down; keep hiding until it has gone.
        while ($state -eq 'Done' -and $wait.Elapsed.TotalSeconds -lt 120)
        {
            $ids = @(Get-Process -Name $names -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
            if ($ids.Count -eq 0) { break }
            if ($hide) { [void](Hide-SandboxWindows -ProcessIds $ids) }
            Start-Sleep -Milliseconds 50
            if ([int]($wait.Elapsed.TotalMilliseconds / 50) % 5 -eq 0) { Invoke-UiRefresh }
        }
        $left = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0)
        {
            Write-PackagerLog 'Closing the Windows Sandbox window.'
            $left | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        # Windows Sandbox needs a moment after its window has gone before it can start again.
        $pause = [System.Diagnostics.Stopwatch]::StartNew()
        while ($pause.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 250; Invoke-UiRefresh }
        if ($state -ne 'NoStart') { break }
        if ($try -eq 2) { Write-PackagerLog 'Windows Sandbox failed to start twice. Close any Windows Sandbox windows (or restart the PC) and try again.' -Level Warn }
    }
    $keep = @(Get-Content -LiteralPath $ours -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notlike 'classic|*' })
    Set-Content -LiteralPath $ours -Value $keep
}

function Invoke-SandboxRun
{
    # One sandbox, one Run-Probe.ps1 execution as SYSTEM. Streams probe.log into the packager log; returns result.json.
    param
    (
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [int]$TimeoutSec = 1800,
        [bool]$Network = $true
    )
    if (-not (Test-Path -LiteralPath $RunDir)) { New-Item -ItemType Directory -Path $RunDir -Force | Out-Null }
    Write-Utf8File -Path (Join-Path $RunDir 'Run-Probe.ps1') -Content $script:SandboxProbeScript
    Write-Utf8File -Path (Join-Path $RunDir 'config.json') -Content ($Config | ConvertTo-Json -Depth 6)
    $logPath    = Join-Path $RunDir 'probe.log'
    $resultPath = Join-Path $RunDir 'result.json'
    foreach ($f in @($logPath, $resultPath)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    $mapped = @(
        @{ Host = $SourceRoot; Sandbox = 'C:\Source'; ReadOnly = $true },
        @{ Host = $RunDir;     Sandbox = 'C:\Probe';  ReadOnly = $false }
    )
    $script:ProbeLogLines = 0
    $tail = {
        if (Test-Path -LiteralPath $logPath)
        {
            $lines = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
            for ($n = $script:ProbeLogLines; $n -lt $lines.Count; $n++) { Write-PackagerLog "  sandbox> $($lines[$n])" }
            $script:ProbeLogLines = $lines.Count
        }
    }
    if ($script:SandboxMode -eq 'Classic' -or -not (Get-WsbPath))
    {
        Invoke-ClassicSandboxRun -RunDir $RunDir -MappedFolders $mapped -TimeoutSec $TimeoutSec -Network $Network -OnTick $tail
        if (-not (Test-Path -LiteralPath $resultPath)) { return $null }
        return ([System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json)
    }

    $id = Start-PackagerSandbox -Network $Network -MappedFolders $mapped
    try
    {
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Probe\Run-Probe.ps1'
        $r = Invoke-Wsb -Arguments @('exec', '--id', $id, '-c', $cmd, '-r', 'System', '--raw') -TimeoutSec $TimeoutSec -OnTick $tail
        & $tail
        if ($r.TimedOut) { Write-PackagerLog "The sandbox run did not finish within $([int]($TimeoutSec / 60)) minutes; stopping it." -Level Warn }
        elseif ($r.ExitCode -ne 0) { Write-PackagerLog "wsb exec reported: $($r.Output)" -Level Warn }
    }
    finally
    {
        Stop-PackagerSandbox -Id $id
    }
    if (-not (Test-Path -LiteralPath $resultPath)) { return $null }
    return ([System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json)
}

function New-ProbeLaunch
{
    # Turns "run this file with these arguments" into the command line used inside the sandbox (C:\Work is the copy).
    param([Parameter(Mandatory)][string]$RelativePath, [string]$Arguments)
    $sandboxFile = Join-Path 'C:\Work' $RelativePath
    $dir = Split-Path -Path $sandboxFile -Parent
    switch ([System.IO.Path]::GetExtension($RelativePath).ToLowerInvariant())
    {
        '.ps1'  { return @{ FilePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'; Arguments = ("-NoProfile -ExecutionPolicy Bypass -File `"$sandboxFile`" $Arguments").Trim(); WorkingDirectory = $dir } }
        { $_ -in @('.cmd', '.bat') } { return @{ FilePath = 'C:\Windows\System32\cmd.exe'; Arguments = ('/c ""' + $sandboxFile + '" ' + $Arguments + '"'); WorkingDirectory = $dir } }
        '.vbs'  { return @{ FilePath = 'C:\Windows\System32\cscript.exe'; Arguments = ("//nologo //B `"$sandboxFile`" $Arguments").Trim(); WorkingDirectory = $dir } }
        '.msi'  { return @{ FilePath = 'C:\Windows\System32\msiexec.exe'; Arguments = ("/i `"$sandboxFile`" /qn /norestart $Arguments").Trim(); WorkingDirectory = $dir } }
        default { return @{ FilePath = $sandboxFile; Arguments = "$Arguments"; WorkingDirectory = $dir } }
    }
}

function Invoke-SandboxProbe
{
    # Tries each candidate in a fresh sandbox (as SYSTEM) and stops at the first that installs silently. Returns every
    # result collected. Candidates are argument strings for the installer.
    param
    (
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Candidates,
        [string]$SourceRoot,                 # folder holding everything the installer needs; default = the installer's folder
        [switch]$CopyWholeSource,            # copy all of SourceRoot into the sandbox, not just the installer
        [string]$DetectionScript,
        [string]$UninstallArgs,
        [string]$AppNameHint,
        [int[]]$SuccessCodes = @(0, 3010, 1641),
        [int]$TimeoutMinutes = 30,          # backstop only; hangs are caught by the idle rules
        [int]$UiGraceSeconds = 30,
        [int]$IdleSeconds = 120,             # a windowless pause this long counts as hung
        [string]$HelpSwitch = '/?',
        [bool]$Network = $true,
        [scriptblock]$OnAttempt              # called as (attempt number, total, candidate) before each sandbox run
    )
    if (-not (Test-WindowsSandbox)) { throw 'Windows Sandbox is not available on this PC.' }
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) { throw "Installer not found: $InstallerPath" }
    $InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
    if (-not $SourceRoot) { $SourceRoot = Split-Path -Path $InstallerPath -Parent }
    $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
    if (-not $InstallerPath.StartsWith($SourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "The installer is not inside $SourceRoot" }
    $rel = $InstallerPath.Substring($SourceRoot.Length + 1)

    $runRoot = Join-Path $script:AppDataDir ('Sandbox\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-PackagerLog "Sandbox runs: $runRoot"
    $results = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($candidate in $Candidates)
    {
        $n++
        $launch = New-ProbeLaunch -RelativePath $rel -Arguments $candidate
        $help = $null
        if ($n -eq 1 -and $HelpSwitch -and [System.IO.Path]::GetExtension($rel) -ieq '.exe') { $help = New-ProbeLaunch -RelativePath $rel -Arguments $HelpSwitch }
        $config = [ordered]@{
            Mode                  = 'Install'
            Label                 = $candidate
            # Not $(if ... { @() }): Windows PowerShell 5.1 writes that empty result to JSON as {}, which the probe read
            # as one blank item and copied the source folder itself instead of its contents.
            CopyItems             = [string[]]@(@($rel) | Where-Object { -not $CopyWholeSource })
            FilePath              = $launch.FilePath
            Arguments             = $launch.Arguments
            WorkingDirectory      = $launch.WorkingDirectory
            Help                  = $help
            TimeoutSec            = $TimeoutMinutes * 60
            UiGraceSec            = $UiGraceSeconds
            IdleSec               = $IdleSeconds
            SuccessCodes          = @($SuccessCodes)
            UninstallArgs         = "$UninstallArgs"
            AppNameHint           = "$AppNameHint"
            DetectionScriptBase64 = $(if ($DetectionScript) { [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($DetectionScript)) } else { '' })
        }
        Write-PackagerLog "Sandbox $n of $($Candidates.Count): $rel $candidate"
        if ($OnAttempt) { & $OnAttempt $n $Candidates.Count $candidate }
        $r = Invoke-SandboxRun -SourceRoot $SourceRoot -RunDir (Join-Path $runRoot "attempt-$n") -Config $config -TimeoutSec ($TimeoutMinutes * 60 * 2 + 300) -Network $Network
        if (-not $r)
        {
            Write-PackagerLog "No result came back for [$candidate]." -Level Warn
            $results.Add([pscustomobject]@{ Candidate = $candidate; InstallSucceeded = $false; Error = 'No result from the sandbox'; Install = $null; NewEntries = @(); PrimaryEntry = $null; Footprint = $null; Uninstall = $null; Help = $null; Detection = $null; RunDir = (Join-Path $runRoot "attempt-$n") })
            continue
        }
        $r | Add-Member -NotePropertyName Candidate -NotePropertyValue $candidate -Force
        $r | Add-Member -NotePropertyName RunDir -NotePropertyValue (Join-Path $runRoot "attempt-$n") -Force
        $results.Add($r)
        if ($r.Error) { Write-PackagerLog "Sandbox reported: $($r.Error)" -Level Warn }
        if ($r.InstallSucceeded)
        {
            Write-PackagerLog "[$candidate] installed silently (exit $($r.Install.ExitCode), $($r.Install.DurationSec)s)."
            break
        }
        Write-PackagerLog "[$candidate] failed: $(Get-ProbeFailureReason -Result $r -SuccessCodes $SuccessCodes)" -Level Warn
    }
    return $results.ToArray()
}

function Get-ProbeFailureReason
{
    param($Result, [int[]]$SuccessCodes = @(0, 3010, 1641))
    $i = $Result.Install
    if ($Result.Error -and -not $i)              { return "$($Result.Error)" }
    if (-not $i)                                 { return 'no result' }
    if ($i.StartFailed)                          { return "did not start ($($i.StdErr))" }
    if ($i.Stuck)                                { return "$($i.Stuck)" }
    if ($i.TimedOut)                             { return 'timed out' }
    if ($null -eq $i.ExitCode)                   { return 'no exit code' }
    if (@($SuccessCodes) -notcontains [int]$i.ExitCode) { return "exit code $($i.ExitCode)" }
    return 'exited cleanly but nothing was installed'
}

function Invoke-SandboxValidation
{
    # Runs the built package in a fresh sandbox exactly as Intune would (SYSTEM, silent): install, detect, uninstall,
    # detect again. Copies the toolkit logs next to the package.
    param
    (
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$DetectName,
        [int[]]$SuccessCodes = @(0, 3010, 1641),
        [string]$DeployMode = 'Silent',
        [int]$TimeoutMinutes = 45,
        [bool]$Network = $true
    )
    if (-not (Test-WindowsSandbox)) { throw 'Windows Sandbox is not available on this PC.' }
    $runDir = Join-Path $script:AppDataDir ('Sandbox\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-validate')
    $config = [ordered]@{
        Mode             = 'Validate'
        Label            = 'End-to-end package test'
        CopyItems        = @('Package', $DetectName)
        DetectScriptName = $DetectName
        DeployMode       = $DeployMode
        TimeoutSec       = $TimeoutMinutes * 60
        UiGraceSec       = 60
        IdleSec          = 120
        SuccessCodes     = @($SuccessCodes)
    }
    Write-PackagerLog 'Validating the package in a fresh sandbox (install, detect, uninstall, detect) as SYSTEM'
    $r = Invoke-SandboxRun -SourceRoot $PackageRoot -RunDir $runDir -Config $config -TimeoutSec ($TimeoutMinutes * 60 * 2 + 300) -Network $Network
    if ($r) { $r | Add-Member -NotePropertyName RunDir -NotePropertyValue $runDir -Force }
    $logs = Join-Path $runDir 'logs'
    if (Test-Path -LiteralPath $logs)
    {
        $dest = Join-Path $PackageRoot 'Validation'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path (Join-Path $logs '*') -Destination $dest -Recurse -Force
        foreach ($f in @('probe.log', 'result.json')) { $src = Join-Path $runDir $f; if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dest -Force } }
    }
    return $r
}

function Get-ProbeSummary
{
    # Human-readable outcome for the dialog / log.
    param([Parameter(Mandatory)]$Results)
    $L = New-Object System.Collections.Generic.List[string]
    $win = @($Results | Where-Object { $_.InstallSucceeded }) | Select-Object -First 1
    if ($win)
    {
        $L.Add("Silent install works with:  $($win.Candidate)")
        $e = $win.PrimaryEntry
        if ($e) { $L.Add("Registered as: $($e.DisplayName) $($e.DisplayVersion)  (publisher: $($e.Publisher), $($e.Location))") }
        foreach ($f in @($win.Footprint.Folders)) { $L.Add("Created folder: $($f.Path)") }
        if (@($win.Footprint.PerUser).Count -gt 0) { $L.Add("WARNING: installed into the SYSTEM profile (a per-user installer): $(@($win.Footprint.PerUser) -join ', ')") }
        if ($win.Detection) { $L.Add("Detection script: $(if ($win.Detection.Detected) { 'DETECTED' } else { 'not detected' })") }
        if ($win.Uninstall)
        {
            $L.Add("Uninstall $(if ($win.Uninstall.Verified) { 'verified' } else { 'attempted, NOT verified' }): `"$($win.Uninstall.File)`" $($win.Uninstall.Arguments)")
        }
        elseif (-not $e) { $L.Add('No uninstall entry appeared; the uninstall could not be tested here.') }
    }
    else
    {
        $L.Add('None of the candidates installed silently:')
        foreach ($r in @($Results)) { $L.Add("  [$($r.Candidate)] - $(Get-ProbeFailureReason -Result $r)") }
    }
    $help = @($Results | Where-Object { $_.Help -and "$($_.Help.Text)".Trim() }) | Select-Object -First 1
    if ($help)
    {
        $switches = @([regex]::Matches($help.Help.Text, '(?<![\w])(?:--?[A-Za-z][\w-]*|/[A-Za-z][\w-]*)') | ForEach-Object { $_.Value } | Select-Object -Unique)
        if ($switches.Count -gt 0) { $L.Add("Switches mentioned by '$($help.Help.Switch)': $($switches -join ' ')") }
    }
    return ($L -join "`n")
}

#endregion

#region ---------------------------------------------------------------- Auto-package: drop anything, get a tested package

# Script names that say nothing about the app; the folder (or zip) name is used instead.
$script:GenericScriptNames = '^(install|setup|deploy|run|main|start|silent|default|go)([-_ ]?(app|all|script|me|silent|x64|x86))?$'

function Get-EntryKind
{
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant())
    {
        '.msi'  { return 'MSI' }
        '.exe'  { return 'EXE' }
        { $_ -in @('.msix', '.appx', '.msixbundle', '.appxbundle') } { return 'MSIX' }
        { $_ -in @('.ps1', '.cmd', '.bat', '.vbs') } { return 'Script' }
    }
    return $null
}

function Get-RelativePath
{
    param([string]$Root, [string]$Path)
    $r = $Root.TrimEnd('\') + '\'
    if ($Path.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($r.Length) }
    return [System.IO.Path]::GetFileName($Path)
}

function Resolve-PackageInput
{
    # Works out what was dropped. A .zip is extracted first; a folder is searched for its entry point; a folder of program
    # files with no installer is a portable app. Returns where the content lives (Root), whether the whole folder ships
    # (IsFolder), the entry file, how to treat it (Kind: MSI, EXE, MSIX, Script, Portable) and a name hint.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Not found: $Path" }
    $item  = Get-Item -LiteralPath $Path -Force
    $notes = New-Object System.Collections.Generic.List[string]
    $forced = $null
    if (-not $item.PSIsContainer -and $item.Extension -ine '.zip')
    {
        $kind = Get-EntryKind -Path $item.FullName
        if (-not $kind) { throw "Don't know how to package '$($item.Name)'. Drop an .msi, .exe, .msix/.appx, .ps1, .cmd, .bat, .vbs, a .zip or a folder." }
        # setup.exe / install.cmd almost always need the files next to them (the MSI the script calls, the CABs the
        # setup reads), so their folder ships too - unless it is a catch-all folder such as Downloads.
        $generic = $item.BaseName -match '^(setup|install|installer)$' -or ($kind -eq 'Script' -and $item.BaseName -match $script:GenericScriptNames)
        $catchAll = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), (Join-Path $env:USERPROFILE 'Downloads'), $env:USERPROFILE, $env:TEMP) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
        if (-not $generic -or $catchAll -contains $item.DirectoryName.TrimEnd('\'))
        {
            $hint = $item.BaseName
            $single = @()
            if ($generic)
            {
                $hint = $item.Directory.Name
                $single = @("Only $($item.Name) was packaged: it sits in $($item.DirectoryName), so its neighbours were not included. Drop its own folder instead if it needs other files.")
            }
            return [pscustomobject]@{ Root = $item.DirectoryName; IsFolder = $false; Entry = $item.FullName; EntryRelative = $item.Name; Kind = $kind; NameHint = $hint; Transforms = @(); UninstallScript = ''; Notes = $single }
        }
        $forced = $item
        $notes.Add("$($item.Name) is packaged together with the rest of its folder, $($item.DirectoryName).")
        $item = Get-Item -LiteralPath $item.DirectoryName -Force
    }

    if ($item.PSIsContainer)
    {
        $folder = $item.FullName.TrimEnd('\')
        $hint   = $item.Name
    }
    else
    {
        $stage = Join-Path $script:AppDataDir ('Staging\' + (Get-SafeName $item.BaseName) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        Write-PackagerLog "Extracting $($item.Name) to $stage"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $stage)
        $folder = $stage
        $notes.Add("Extracted $($item.Name) to $stage")
        $hint = $item.BaseName
    }

    # A wrapper folder with nothing but one subfolder: use the subfolder.
    $files = @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction SilentlyContinue)
    while ($files.Count -eq 0)
    {
        $dirs = @(Get-ChildItem -LiteralPath $folder -Directory -Force -ErrorAction SilentlyContinue)
        if ($dirs.Count -ne 1) { break }
        $folder = $dirs[0].FullName
        $files  = @(Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction SilentlyContinue)
    }

    $scriptOrder = @('.ps1', '.cmd', '.bat', '.vbs')
    $isScript = { param($f) $scriptOrder -contains $f.Extension.ToLowerInvariant() }
    $installScripts = @($files | Where-Object { (& $isScript $_) -and $_.BaseName -match '^(install|setup|deploy|silent[-_ ]?install)' } | Sort-Object { $scriptOrder.IndexOf($_.Extension.ToLowerInvariant()) })
    $uninstallScripts = @($files | Where-Object { (& $isScript $_) -and $_.BaseName -match '^(uninstall|remove)' } | Sort-Object { $scriptOrder.IndexOf($_.Extension.ToLowerInvariant()) })
    $msis  = @($files | Where-Object { $_.Extension -ieq '.msi' })
    $exes  = @($files | Where-Object { $_.Extension -ieq '.exe' })
    $appx  = @($files | Where-Object { $_.Extension -match '^\.(msix|appx|msixbundle|appxbundle)$' })
    $setup = @($exes | Where-Object { $_.BaseName -match '^(setup|install|installer)$' }) | Select-Object -First 1

    $entry = $null; $kind = $null
    if ($forced)                               { $entry = $forced; $kind = Get-EntryKind -Path $forced.FullName }
    elseif ($installScripts.Count -gt 0)       { $entry = $installScripts[0]; $kind = 'Script' }
    elseif ($msis.Count -eq 1 -and -not $setup) { $entry = $msis[0]; $kind = 'MSI' }
    elseif ($setup)                            { $entry = $setup; $kind = 'EXE' }
    elseif ($msis.Count -gt 1)
    {
        $entry = $msis | Sort-Object Length -Descending | Select-Object -First 1
        $kind  = 'MSI'
        $notes.Add("Several MSIs in the folder; using the largest, $($entry.Name). The others ship alongside it.")
    }
    elseif ($appx.Count -gt 0)                 { $entry = $appx[0]; $kind = 'MSIX' }
    elseif ($exes.Count -gt 0)
    {
        $installers = @($exes | Where-Object { (Get-InstallerEngine -Path $_.FullName) -ne 'Unknown' })
        if ($installers.Count -eq 1) { $entry = $installers[0]; $kind = 'EXE' }
        elseif ($installers.Count -gt 1)
        {
            $named = @($installers | Where-Object { $_.BaseName -match '(?i)setup|install' })
            $entry = $(if ($named.Count -gt 0) { $named[0] } else { $installers | Sort-Object Length -Descending | Select-Object -First 1 })
            $kind  = 'EXE'
            $notes.Add("Several installers in the folder; using $($entry.Name).")
        }
    }
    if (-not $kind)
    {
        # No installer: a portable program if there is an EXE anywhere near the top.
        $allExe = @(Get-ChildItem -LiteralPath $folder -Recurse -Depth 2 -File -Filter '*.exe' -Force -ErrorAction SilentlyContinue)
        if ($allExe.Count -gt 0)
        {
            $infos = @($allExe | ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Size = $_.Length } })
            $main  = Select-MainExecutable -Exes $infos -NameHint $hint
            $entry = Get-Item -LiteralPath $main.Path
            $kind  = 'Portable'
            $notes.Add("No installer found; treating the folder as a portable app with $(Get-RelativePath -Root $folder -Path $entry.FullName) as the program.")
        }
    }
    if (-not $kind) { throw "No installer, script or program found in $folder." }

    $transforms = @()
    if ($kind -eq 'MSI') { $transforms = @($files | Where-Object { $_.Extension -ieq '.mst' } | ForEach-Object { $_.Name }) }
    $uninstallRel = ''
    if ($uninstallScripts.Count -gt 0) { $uninstallRel = $uninstallScripts[0].Name }
    if ($kind -eq 'Script' -and $entry.BaseName -notmatch $script:GenericScriptNames -and -not $item.PSIsContainer -and $item.Extension -ine '.zip') { $hint = $entry.BaseName }

    return [pscustomobject]@{
        Root            = $folder
        IsFolder        = $true
        Entry           = $entry.FullName
        EntryRelative   = Get-RelativePath -Root $folder -Path $entry.FullName
        Kind            = $kind
        NameHint        = $hint
        Transforms      = $transforms
        UninstallScript = $uninstallRel
        Notes           = @($notes)
    }
}

function Select-MainExecutable
{
    # The program a user would launch: a Start menu shortcut target first, then the EXE named like the app, then the
    # biggest EXE nearest the top - skipping uninstallers, updaters and helpers.
    param([object[]]$Exes, [string]$NameHint, [string[]]$ShortcutTargets)
    $skip  = '(?i)^(unins|uninst|uninstall|update|updater|autoupdate|crash|crashpad|crashreporter|helper|elevate|setup|install|installer|vc_?redist|dotnet|notification_helper|squirrel|createdump|bsdtar|7z\.sfx)'
    $all   = @($Exes | Where-Object { $_ -and $_.Path })
    $cands = @($all | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Path) -notmatch $skip })
    if ($cands.Count -eq 0) { $cands = $all }
    if ($cands.Count -eq 0) { return $null }
    foreach ($t in @($ShortcutTargets | Where-Object { $_ }))
    {
        $hit = @($cands | Where-Object { $_.Path -ieq $t }) | Select-Object -First 1
        if ($hit) { return $hit }
    }
    $h = ("$NameHint" -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    if ($h.Length -ge 3)
    {
        $hit = @($cands | Where-Object {
            $b = ([System.IO.Path]::GetFileNameWithoutExtension($_.Path) -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
            $b.Length -ge 3 -and ($h.Contains($b) -or $b.Contains($h))
        } | Sort-Object { $_.Path.Split('\').Count }) | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return @($cands | Sort-Object @{ Expression = { $_.Path.Split('\').Count } }, @{ Expression = { [int64]$_.Size }; Descending = $true }) | Select-Object -First 1
}

function ConvertTo-PortablePath
{
    # C:\Program Files\X (as seen in the sandbox) -> $env:ProgramFiles\X, so generated code works on any system drive.
    param([string]$Path)
    $map = @(
        @('C:\Program Files (x86)', '${env:ProgramFiles(x86)}'),
        @('C:\Program Files', '$env:ProgramFiles'),
        @('C:\ProgramData', '$env:ProgramData'),
        @('C:\Users\Public', '$env:PUBLIC'),
        @('C:\Windows', '$env:SystemRoot')
    )
    foreach ($m in $map)
    {
        if ($Path -ieq $m[0] -or $Path.StartsWith($m[0] + '\', [StringComparison]::OrdinalIgnoreCase)) { return $m[1] + $Path.Substring($m[0].Length) }
    }
    return $Path
}

function Get-VersionedNamePattern
{
    # "Microsoft Visual C++ ... (x64) - 14.44.35211" with version 14.44.35211.0 -> "Microsoft Visual C++ ... (x64) - *",
    # so detection and uninstall keep matching after an upgrade. $null when the name does not contain the version.
    param([string]$DisplayName, [string]$Version)
    if (-not $DisplayName -or -not $Version) { return $null }
    $v = Get-CleanVersion $Version
    $tries = New-Object System.Collections.Generic.List[string]
    $parts = @($v.Split('.'))
    for ($n = $parts.Count; $n -ge 2; $n--) { $tries.Add(($parts[0..($n - 1)] -join '.')) }
    foreach ($t in $tries)
    {
        $i = $DisplayName.IndexOf($t)
        if ($i -ge 0)
        {
            $after = $DisplayName.Substring($i + $t.Length)
            if ($after -match '^\d') { continue }
            return [System.Management.Automation.WildcardPattern]::Escape($DisplayName.Substring(0, $i)) + '*' + [System.Management.Automation.WildcardPattern]::Escape($after)
        }
    }
    return $null
}

function New-FootprintUninstallCode
{
    # Uninstall code for installs that register no uninstaller: undo what the install was seen to create in the sandbox.
    param([Parameter(Mandatory)]$Footprint)
    $q = { param($t) ConvertTo-PsExpandableString $t }
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('## Generated by PSADT Packager from what the install created in Windows Sandbox (it registered no uninstaller).')
    $L.Add('## Review it before relying on it in production.')
    $services = @($Footprint.Services | ForEach-Object { $_.Name } | Where-Object { $_ })
    if ($services.Count -gt 0)
    {
        $L.Add('foreach ($serviceName in @(' + (($services | ForEach-Object { ConvertTo-PsSingleQuoted $_ }) -join ', ') + '))')
        $L.Add('{')
        $L.Add('    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)')
        $L.Add('    {')
        $L.Add('        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue')
        $L.Add('        & "$env:SystemRoot\System32\sc.exe" delete $serviceName | Out-Null')
        $L.Add('    }')
        $L.Add('}')
    }
    foreach ($t in @($Footprint.Tasks | Where-Object { $_ }))
    {
        $i = $t.LastIndexOf('\')
        $L.Add('Get-ScheduledTask -TaskPath ' + (ConvertTo-PsSingleQuoted $t.Substring(0, $i + 1)) + ' -TaskName ' + (ConvertTo-PsSingleQuoted $t.Substring($i + 1)) + ' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false')
    }
    $links = @($Footprint.Shortcuts | ForEach-Object { $_.Path } | Where-Object { $_ })
    if ($links.Count -gt 0)
    {
        $L.Add('foreach ($shortcut in @(' + (($links | ForEach-Object { '"' + (& $q (ConvertTo-PortablePath $_)) + '"' }) -join ', ') + '))')
        $L.Add('{')
        $L.Add('    if (Test-Path -LiteralPath $shortcut) { Remove-ADTFile -LiteralPath $shortcut }')
        $L.Add('}')
        $programs = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
        $menuDirs = @($links | ForEach-Object { Split-Path -Path $_ -Parent } | Where-Object { $_ -like "$programs\*" } | Select-Object -Unique)
        if ($menuDirs.Count -gt 0)
        {
            $L.Add('foreach ($menuFolder in @(' + (($menuDirs | ForEach-Object { '"' + (& $q (ConvertTo-PortablePath $_)) + '"' }) -join ', ') + '))')
            $L.Add('{')
            $L.Add('    if ((Test-Path -LiteralPath $menuFolder) -and -not (Get-ChildItem -LiteralPath $menuFolder -Force)) { Remove-ADTFolder -LiteralPath $menuFolder }')
            $L.Add('}')
        }
    }
    $folders = @($Footprint.Folders | Where-Object { $_ -and -not $_.PerUser } | ForEach-Object { $_.Path })
    if ($folders.Count -gt 0)
    {
        $L.Add('foreach ($folder in @(' + (($folders | ForEach-Object { '"' + (& $q (ConvertTo-PortablePath $_)) + '"' }) -join ', ') + '))')
        $L.Add('{')
        $L.Add('    if (Test-Path -LiteralPath $folder) { Remove-ADTFolder -LiteralPath $folder }')
        $L.Add('}')
    }
    $keys = @($Footprint.RegistryKeys | Where-Object { $_ } | ForEach-Object { 'HKLM:' + $_.Substring(4) })
    if ($keys.Count -gt 0)
    {
        $L.Add('foreach ($key in @(' + (($keys | ForEach-Object { ConvertTo-PsSingleQuoted $_ }) -join ', ') + '))')
        $L.Add('{')
        $L.Add('    if (Test-Path -LiteralPath $key) { Remove-ADTRegistryKey -LiteralPath $key -Recurse }')
        $L.Add('}')
    }
    return ($L -join "`r`n")
}

function Set-DefinitionFromProbe
{
    # Applies a successful sandbox run: install arguments, uninstall (the proven one where possible), detection, and
    # anything the Application tab was missing. -Auto lets what the installer registered override guesses made from the file.
    param([Parameter(Mandatory)]$Def, [Parameter(Mandatory)]$Result, [switch]$Auto, [string]$NameHint)
    if (-not $Result.InstallSucceeded) { return $Def }
    if ($Def.Install.Type -eq 'EXE') { $Def.Install.Arguments = "$($Result.Candidate)" }

    $entry = $Result.PrimaryEntry
    if (-not $entry) { $entry = @($Result.NewEntries | Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 }) | Select-Object -First 1 }
    $fp = $Result.Footprint
    $mainExe = $null
    if ($fp)
    {
        $exes = @(foreach ($f in @($fp.Folders)) { if (-not $f.PerUser) { @($f.Exes) } })
        $hint = "$($Def.App.Name)"; if (-not $hint) { $hint = $NameHint }
        $mainExe = Select-MainExecutable -Exes $exes -NameHint $hint -ShortcutTargets @($fp.Shortcuts | ForEach-Object { $_.Target })
    }

    if ($entry)
    {
        if ($entry.Publisher -and ($Auto -or -not "$($Def.App.Vendor)".Trim()))     { $Def.App.Vendor  = "$($entry.Publisher)".Trim() }
        if ($entry.DisplayVersion -and ($Auto -or -not "$($Def.App.Version)".Trim())) { $Def.App.Version = Get-CleanVersion "$($entry.DisplayVersion)" }
        # What the installer registers names the app better than its own version resource (an Omaha stub calls
        # itself "BraveSoftware Update"; the browser it installs registers as "Brave").
        if ($Auto -or -not "$($Def.App.Name)".Trim()) { $Def.App.Name = Get-CleanAppName -Name "$($entry.DisplayName)" -Version "$($entry.DisplayVersion)" }
        if (-not "$($Def.App.Arch)".Trim())
        {
            # The program's own PE header first: a 32-bit updater (Omaha) registers a 64-bit browser in the 32-bit view.
            if ($mainExe -and $mainExe.PSObject.Properties['Machine'] -and "$($mainExe.Machine)") { $Def.App.Arch = "$($mainExe.Machine)" }
            elseif ($entry.Location -eq 'LocalMachine\Registry32') { $Def.App.Arch = 'x86' }
            elseif ($entry.Location -eq 'LocalMachine\Registry64') { $Def.App.Arch = 'x64' }
        }
        $pattern = Get-VersionedNamePattern -DisplayName "$($entry.DisplayName)" -Version "$($entry.DisplayVersion)"
        $Def.Detection.Type        = 'Registry'
        $Def.Detection.DisplayName = $(if ($pattern) { $pattern } else { "$($entry.DisplayName)" })
        $Def.Detection.MatchMode   = $(if ($pattern) { 'Wildcard' } else { 'Exact' })
        $Def.Detection.MinVersion  = Get-CleanVersion "$($entry.DisplayVersion)"
    }
    elseif ($mainExe)
    {
        $Def.Detection.Type             = 'File'
        $Def.Detection.FilePath         = ConvertTo-PortablePath $mainExe.Path
        $Def.Detection.MinVersion       = $(if ("$($mainExe.FileVersion)" -match '^\d+(\.\d+)+$' -and "$($mainExe.FileVersion)" -ne '0.0.0.0') { "$($mainExe.FileVersion)" } else { '' })
        $Def.Detection.CheckFileVersion = [bool]$Def.Detection.MinVersion
        if (-not "$($Def.App.Version)".Trim() -and $Def.Detection.MinVersion) { $Def.App.Version = $Def.Detection.MinVersion }
    }
    elseif ($fp -and @($fp.Services).Count -gt 0)
    {
        $svc = @($fp.Services)[0].Name
        $Def.Detection.Type   = 'Script'
        $Def.Detection.Script = "# The install creates the '$svc' service.`r`nif (Get-Service -Name " + (ConvertTo-PsSingleQuoted $svc) + " -ErrorAction SilentlyContinue)`r`n{`r`n    Write-Output 'Detected: service $svc'`r`n    exit 0`r`n}`r`nexit 1"
    }
    elseif ($fp -and @($fp.Folders | Where-Object { -not $_.PerUser }).Count -gt 0)
    {
        $folder = ConvertTo-PortablePath (@($fp.Folders | Where-Object { -not $_.PerUser })[0].Path)
        $Def.Detection.Type   = 'Script'
        $Def.Detection.Script = "# The install creates this folder (it has no program file or uninstall entry to check).`r`n`$folder = """ + (ConvertTo-PsExpandableString $folder) + """`r`nif (Test-Path -LiteralPath `$folder -PathType Container)`r`n{`r`n    Write-Output ""Detected: `$folder""`r`n    exit 0`r`n}`r`nexit 1"
    }
    elseif ($fp -and @($fp.RegistryKeys).Count -gt 0)
    {
        $key = 'HKLM:' + (@($fp.RegistryKeys)[0]).Substring(4)
        $Def.Detection.Type   = 'Script'
        $Def.Detection.Script = "# The install creates this registry key.`r`n`$key = " + (ConvertTo-PsSingleQuoted $key) + "`r`nif (Test-Path -LiteralPath `$key)`r`n{`r`n    Write-Output ""Detected: `$key""`r`n    exit 0`r`n}`r`nexit 1"
    }
    elseif ($fp -and @($fp.Shortcuts).Count -gt 0)
    {
        $Def.Detection.Type             = 'File'
        $Def.Detection.FilePath         = ConvertTo-PortablePath (@($fp.Shortcuts)[0].Path)
        $Def.Detection.MinVersion       = ''
        $Def.Detection.CheckFileVersion = $false
    }

    $u = $Result.Uninstall
    if ($Def.Uninstall.Type -eq 'Script' -and "$($Def.Uninstall.File)".Trim())
    {
        # An uninstall script shipped with the app is the author's intent; keep it.
    }
    elseif ($u -and $u.Verified)
    {
        if ("$($u.File)" -match '(?i)msiexec' -and "$($u.Arguments)" -match '\{[0-9A-Fa-f\-]{36}\}')
        {
            $Def.Uninstall.Type        = 'MSI'
            $Def.Uninstall.ProductCode = $Matches[0]
            $Def.Uninstall.Arguments   = ''
        }
        elseif ($entry)
        {
            # By name, with exactly the arguments proven in the sandbox: the package looks up the registered
            # command at uninstall time (quiet one first, as the probe did), so it keeps working after the app has
            # updated itself and moved its uninstaller (Chromium browsers keep it in a version-numbered folder).
            $pattern = Get-VersionedNamePattern -DisplayName "$($entry.DisplayName)" -Version "$($entry.DisplayVersion)"
            $Def.Uninstall.Type            = 'Name'
            $Def.Uninstall.Name            = $(if ($pattern) { $pattern } else { "$($entry.DisplayName)" })
            $Def.Uninstall.NameIsRegex     = $false
            $Def.Uninstall.ApplicationType = 'EXE'
            $Def.Uninstall.Arguments       = "$($u.Arguments)"
        }
        else
        {
            $Def.Uninstall.Type      = 'EXE'
            $Def.Uninstall.File      = ConvertTo-PortablePath "$($u.File)"
            $Def.Uninstall.Arguments = "$($u.Arguments)"
        }
        # The uninstall was proven by its outcome (entry gone, detection negative); if the uninstaller reports that
        # with a non-standard exit code (Chromium's setup.exe: 19 = uninstall successful), the package must accept it.
        if ($null -ne $u.ExitCode -and @(0, 1641, 3010) -notcontains [int]$u.ExitCode) { $Def.Uninstall.SuccessExitCodes = @([int]$u.ExitCode) }
    }
    elseif ($entry)
    {
        $pattern = Get-VersionedNamePattern -DisplayName "$($entry.DisplayName)" -Version "$($entry.DisplayVersion)"
        $Def.Uninstall.Type        = 'Name'
        $Def.Uninstall.Name        = $(if ($pattern) { $pattern } else { "$($entry.DisplayName)" })
        $Def.Uninstall.NameIsRegex = $false
    }
    elseif ($fp -and (@($fp.Folders).Count + @($fp.Shortcuts).Count + @($fp.RegistryKeys).Count + @($fp.Services).Count + @($fp.Tasks).Count) -gt 0)
    {
        $Def.Uninstall.Type         = 'Custom'
        $Def.Uninstall.CustomScript = New-FootprintUninstallCode -Footprint $fp
    }

    if ($Auto -and $mainExe -and @($Def.Install.ProcessesToClose | Where-Object { "$_".Trim() }).Count -eq 0)
    {
        $Def.Install.ProcessesToClose = @([System.IO.Path]::GetFileNameWithoutExtension($mainExe.Path))
    }
    return $Def
}

function Set-DefinitionForPortable
{
    # A program with no installer: copy it to Program Files, add a Start menu shortcut; uninstall removes both.
    param([Parameter(Mandatory)]$Def, [Parameter(Mandatory)]$PackageInput)
    $exe = Get-Item -LiteralPath $PackageInput.Entry
    $vi  = $exe.VersionInfo
    $split = Split-NameAndVersion $PackageInput.NameHint
    $version = Get-FileVersionText $vi
    # Trust the product name only when it relates to the program or folder name (a renamed or bundled EXE can carry
    # someone else's, e.g. "Microsoft Windows Operating System").
    $name  = Get-CleanAppName -Name "$($vi.ProductName)" -Version $version
    $alnum = { param($s) ("$s" -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
    $pn = & $alnum $name; $eb = & $alnum $exe.BaseName; $hn = & $alnum $split.Name
    $related = $pn -and (($eb.Length -ge 3 -and ($pn.Contains($eb) -or $eb.Contains($pn))) -or ($hn.Length -ge 3 -and ($pn.Contains($hn) -or $hn.Contains($pn))))
    if (-not $related)
    {
        $name = Get-CleanAppName -Name $split.Name
        if ($split.Version) { $version = $split.Version }
    }
    if (-not $version) { $version = $split.Version }
    $Def.App.Name    = $name
    $Def.App.Version = $version
    $Def.App.Vendor  = Get-CleanVendor -Text "$($vi.CompanyName)" -Path $exe.FullName
    $arch = Get-ArchFromText "$($exe.Name) $($PackageInput.NameHint)"
    if (-not $arch) { $arch = Get-PeMachine -Path $exe.FullName }
    $Def.App.Arch = $arch

    $dirName = (($name -replace '[\\/:*?"<>|]', '') -replace '\s{2,}', ' ').Trim()
    if (-not $dirName) { $dirName = Get-SafeName $PackageInput.NameHint }
    $installDir = '$env:ProgramFiles\' + $dirName
    $exeRel   = $PackageInput.EntryRelative
    $shortcut = '$env:ProgramData\Microsoft\Windows\Start Menu\Programs\' + $dirName + '.lnk'
    $q = { param($t) '"' + (ConvertTo-PsExpandableString $t) + '"' }

    $Def.Sources.Files = @($PackageInput.Root.TrimEnd('\') + '\*')
    $Def.Install.Type  = 'Custom'
    $Def.Install.File  = ''
    $Def.Install.ProcessesToClose = @([System.IO.Path]::GetFileNameWithoutExtension($exe.Name))
    $Def.Install.CustomScript = @(
        '## Portable program (no installer): copy it to Program Files and add a Start menu shortcut.'
        '$installDir = ' + (& $q $installDir)
        'Copy-ADTFile -Path "$($adtSession.DirFiles)\*" -Destination $installDir -Recurse'
        'New-ADTShortcut -LiteralPath ' + (& $q $shortcut) + ' -TargetPath (Join-Path -Path $installDir -ChildPath ' + (ConvertTo-PsSingleQuoted $exeRel) + ') -WorkingDirectory $installDir'
    ) -join "`r`n"
    $Def.Uninstall.Type = 'Custom'
    $Def.Uninstall.CustomScript = @(
        '## Remove the copied program and its Start menu shortcut.'
        '$shortcut = ' + (& $q $shortcut)
        'if (Test-Path -LiteralPath $shortcut) { Remove-ADTFile -LiteralPath $shortcut }'
        '$installDir = ' + (& $q $installDir)
        'if (Test-Path -LiteralPath $installDir) { Remove-ADTFolder -LiteralPath $installDir }'
    ) -join "`r`n"
    # Detection compares the file version, so the minimum must be the file's own (not a version from the zip name).
    $fileVersion = '{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart
    if ($fileVersion -eq '0.0.0.0') { $fileVersion = '' }
    $Def.Detection.Type             = 'File'
    $Def.Detection.FilePath         = $installDir + '\' + $exeRel
    $Def.Detection.MinVersion       = $fileVersion
    $Def.Detection.CheckFileVersion = [bool]$fileVersion
    return $Def
}

function New-AutoPackageReport
{
    # AutoPackage-Report.md: what was decided, why, and what the sandbox proved.
    param([Parameter(Mandatory)]$Context)
    $c   = $Context
    $def = $c.Definition
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# Auto-package report: $("$($def.App.Vendor) $($def.App.Name) $($def.App.Version)".Trim())")
    $L.Add('')
    $statusText = switch ($c.Status)
    {
        'Validated'      { 'VALIDATED - installed, detected, uninstalled and confirmed gone in Windows Sandbox as SYSTEM, the way Intune runs it.' }
        'Built'          { 'BUILT, NOT VALIDATED - the package was generated but not run end to end (see notes).' }
        default          { 'NEEDS ATTENTION - see the warnings below before deploying.' }
    }
    $L.Add("**Status:** $statusText")
    $L.Add('')
    $L.Add("Input: ``$($c.InputPath)`` ($($c.Input.Kind)$(if ($c.Info -and $c.Info.Engine -and $c.Info.Engine -notin @('MSI', 'MSIX', 'Script')) { ", $($script:SilentPresets[$c.Info.Engine].Label)" }))  ")
    $L.Add("Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by PSADT Packager $script:PackagerVersion.")
    $L.Add('')
    if (@($c.Warnings).Count -gt 0)
    {
        $L.Add('## Warnings')
        $L.Add('')
        foreach ($w in $c.Warnings) { $L.Add("- $w") }
        $L.Add('')
    }
    $L.Add('## What was decided')
    $L.Add('')
    $L.Add('| Setting | Value | How it was determined |')
    $L.Add('| --- | --- | --- |')
    foreach ($row in @($c.Decisions)) { $L.Add("| $($row.Setting) | $(($row.Value -replace '\|', '\|') -replace "`r?`n", ' ') | $($row.Basis) |") }
    $L.Add('')

    $v = $null
    if ($c.Validation) { $v = $c.Validation.Validation }
    $L.Add('## End-to-end test')
    $L.Add('')
    if ($v)
    {
        $fmt = { param($r) if (-not $r) { 'not run' } elseif ($r.Stuck) { "STUCK: $($r.Stuck)" } elseif ($r.TimedOut) { 'timed out' } else { "exit $($r.ExitCode) in $($r.DurationSec)s" } }
        $L.Add('| Step | Result |')
        $L.Add('| --- | --- |')
        $L.Add("| Install (``Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`` as SYSTEM) | $(& $fmt $v.Install) $(if ($v.InstallOk) { '- OK' } else { '- FAILED' }) |")
        $L.Add("| Detection after install | $(if ($v.DetectAfterInstall.Detected) { "$($v.DetectAfterInstall.Output)" } else { "NOT detected (exit $($v.DetectAfterInstall.ExitCode))" }) |")
        $L.Add("| Uninstall | $(& $fmt $v.Uninstall) $(if ($v.UninstallOk) { '- OK' } else { '- FAILED' }) |")
        $L.Add("| Detection after uninstall | $(if ($v.DetectAfterUninstall.Detected) { "STILL detected: $($v.DetectAfterUninstall.Output)" } else { 'Not detected - OK' }) |")
        $L.Add('')
        $left = $v.Leftovers
        $leftItems = @(@($left.Entries) + @($left.Folders | ForEach-Object { $_.Path }) + @($left.Shortcuts | ForEach-Object { $_.Path }) + @($left.Services | ForEach-Object { "service $($_.Name)" }) + @($left.Tasks) + @($left.RegistryKeys)) | Where-Object { $_ }
        if ($leftItems.Count -gt 0)
        {
            $L.Add('Left behind after uninstall (worth a look; often settings or caches the vendor keeps on purpose):')
            $L.Add('')
            foreach ($i in $leftItems) { $L.Add("- ``$i``") }
            $L.Add('')
        }
        $L.Add('Toolkit logs from the test run are in `Validation\`.')
    }
    else
    {
        $L.Add("Not run. $($c.ValidationNote)")
    }
    $L.Add('')

    if (@($c.Probe).Count -gt 0)
    {
        $L.Add('## Sandbox runs of the installer')
        $L.Add('')
        $n = 0
        foreach ($r in @($c.Probe))
        {
            $n++
            $outcome = if ($r.InstallSucceeded) { 'installed silently' } else { Get-ProbeFailureReason -Result $r }
            $L.Add("$n. ``$($c.Input.EntryRelative) $($r.Candidate)`` - $outcome")
        }
        $L.Add('')
        $win = @($c.Probe | Where-Object { $_.InstallSucceeded }) | Select-Object -First 1
        if ($win)
        {
            $fp = $win.Footprint
            $L.Add('What the install created:')
            $L.Add('')
            foreach ($e in @($win.NewEntries)) { $L.Add("- Uninstall entry: $($e.DisplayName) $($e.DisplayVersion) ($($e.Location)$(if ($e.SystemComponent -eq 1) { ', hidden' }))") }
            foreach ($f in @($fp.Folders)) { $L.Add("- Folder: ``$($f.Path)``") }
            foreach ($s in @($fp.Shortcuts)) { $L.Add("- Shortcut: ``$($s.Path)``") }
            foreach ($s in @($fp.Services)) { $L.Add("- Service: $($s.Name) ($($s.DisplayName))") }
            foreach ($t in @($fp.Tasks)) { $L.Add("- Scheduled task: ``$t``") }
            foreach ($k in @($fp.RegistryKeys)) { $L.Add("- Registry key: ``$k``") }
            $L.Add('')
        }
        $help = @($c.Probe | Where-Object { $_.Help -and "$($_.Help.Text)".Trim() }) | Select-Object -First 1
        if ($help)
        {
            $L.Add("Help text the installer showed for ``$($help.Help.Switch)``:")
            $L.Add('')
            $L.Add('```')
            $L.Add(("$($help.Help.Text)".Trim() -split "`r?`n" | Select-Object -First 40) -join "`r`n")
            $L.Add('```')
            $L.Add('')
        }
    }
    if (@($c.Notes).Count -gt 0)
    {
        $L.Add('## Notes')
        $L.Add('')
        foreach ($n in $c.Notes) { $L.Add("- $n") }
        $L.Add('')
    }
    return (($L -join "`r`n") + "`r`n")
}

function Get-AutoDecisions
{
    # One row per setting for the report: the value that went into the package and the evidence behind it.
    param($Def, $PackageInput, $Info, $Win, [int]$Attempts, [int]$WinAttempt)
    $rows = New-Object System.Collections.Generic.List[object]
    $add = { param($s, $v, $b) $rows.Add([pscustomobject]@{ Setting = $s; Value = "$v"; Basis = $b }) }
    $entry = $null
    if ($Win) { $entry = $Win.PrimaryEntry }
    $fromFile = switch ($PackageInput.Kind) { 'MSI' { 'MSI Property table' } 'MSIX' { 'package manifest' } 'Portable' { "version resource of $([System.IO.Path]::GetFileName($PackageInput.Entry))" } default { 'version resource of the installer' } }

    & $add 'Name' $Def.App.Name $(if ($entry -and $Def.App.Name -eq (Get-CleanAppName -Name "$($entry.DisplayName)" -Version "$($entry.DisplayVersion)")) { 'DisplayName of the uninstall entry the installer created, version and architecture stripped' } elseif ($PackageInput.Kind -eq 'Script' -or -not $Info -or -not $Info.Name) { "Folder / file name ($($PackageInput.NameHint))" } else { "$fromFile, version and architecture stripped" })
    & $add 'Vendor' $Def.App.Vendor $(if ($entry -and $entry.Publisher -and $Def.App.Vendor -eq "$($entry.Publisher)".Trim()) { 'Publisher of the uninstall entry the installer created' } elseif ($Def.App.Vendor) { $fromFile } else { 'Not found - fill in' })
    & $add 'Version' $Def.App.Version $(if ($entry -and $entry.DisplayVersion -and $Def.App.Version -eq (Get-CleanVersion "$($entry.DisplayVersion)")) { 'DisplayVersion of the uninstall entry the installer created' } elseif ($PackageInput.Kind -ne 'Script' -and $Info -and $Info.Version -eq $Def.App.Version) { $fromFile } elseif ($Def.App.Version -and "$($PackageInput.NameHint)$([System.IO.Path]::GetFileName($PackageInput.Entry))" -match [regex]::Escape($Def.App.Version)) { "Folder / file name ($($PackageInput.NameHint))" } else { 'Not found - a default; check it' })
    & $add 'Architecture' $Def.App.Arch $(if ($Def.App.Arch) { 'MSI template, file name, PE header or registry view of the uninstall entry' } else { 'Unknown - the app is allowed on x86 and x64' })

    $i = $Def.Install
    switch ($i.Type)
    {
        'MSI'    { & $add 'Install' "$($i.File) $($i.Arguments)".Trim() 'Windows Installer: Start-ADTMsiProcess adds /qn, /norestart and a verbose log' }
        'EXE'    { & $add 'Install' "$($i.File) $($i.Arguments)" $(if ($Win) { "Proven silent in Windows Sandbox as SYSTEM (attempt $WinAttempt of $Attempts)" } else { 'Installer-type default - NOT proven' }) }
        'Script' { & $add 'Install' "$($i.File) $($i.Arguments)".Trim() $(if ($Win) { 'Runs the script; ran cleanly as SYSTEM in Windows Sandbox' } else { 'Runs the script - not tested' }) }
        'MSIX'   { & $add 'Install' $i.File 'Provisioned for all users with Add-AppxProvisionedPackage' }
        'Custom' { & $add 'Install' 'Copy to Program Files + Start menu shortcut' 'Portable program - no installer in the input' }
    }
    $u = $Def.Uninstall
    $ub = switch ($u.Type)
    {
        'MSI'    { if ($Win -and $Win.Uninstall -and $Win.Uninstall.Verified) { 'MSI product code from the uninstall entry; uninstall proven in Sandbox' } else { 'MSI product code read from the MSI' } }
        'EXE'    { 'Uninstall command the installer registered; proven in Sandbox (entry removed, detection negative)' }
        'Name'
        {
            if (-not $entry) { 'Guessed from the product name - NOT proven (nothing was installed in Sandbox)' }
            elseif ($Win.Uninstall -and $Win.Uninstall.Verified) { 'Runs the uninstall command the installer registered (looked up by its exact DisplayName at uninstall time), with the arguments proven in Sandbox; it keeps working after the app updates itself' }
            elseif ($Win.Uninstall) { 'Registered uninstall command, by the DisplayName the installer registered (it did not prove silent in Sandbox - check)' }
            else { 'Registered uninstall command, by the DisplayName the installer registered' }
        }
        'Script' { 'Uninstall script shipped with the app' }
        'MSIX'   { 'Removes the provisioned and installed package' }
        'Custom' { if ($PackageInput.Kind -eq 'Portable') { 'Removes the copied folder and shortcut' } else { 'Generated from what the install created in Sandbox - review' } }
        default  { 'None' }
    }
    $uv = switch ($u.Type)
    {
        'MSI'    { $(if ("$($u.ProductCode)".Trim()) { "$($u.ProductCode)".Trim() } else { "$($i.ProductCode)".Trim() }) }
        'EXE'    { "`"$($u.File)`" $($u.Arguments)" }
        'Name'   { "$($u.Name) $($u.Arguments)".Trim() }
        'Script' { $u.File }
        'MSIX'   { $u.PackageName }
        'Custom'
        {
            if ($Win -and $Win.Footprint -and $PackageInput.Kind -ne 'Portable')
            {
                $fp = $Win.Footprint
                $items = @(@($fp.Services | ForEach-Object { "service $($_.Name)" }) + @($fp.Tasks | ForEach-Object { "task $_" }) + @($fp.Shortcuts | ForEach-Object { ConvertTo-PortablePath $_.Path }) + @($fp.Folders | Where-Object { -not $_.PerUser } | ForEach-Object { ConvertTo-PortablePath $_.Path }) + @($fp.RegistryKeys)) | Where-Object { $_ }
                'Removes ' + ($items -join ', ')
            }
            elseif ($PackageInput.Kind -eq 'Portable') { 'Removes ' + (Split-Path -Path $Def.Detection.FilePath -Parent) + ' and its Start menu shortcut' }
            else { 'Custom script (Uninstall tab)' }
        }
        default  { '' }
    }
    & $add 'Uninstall' $uv $ub
    $d = $Def.Detection
    $dv = switch ($d.Type) { 'MSI' { "Product code $($d.ProductCode)$(if ($d.MinVersion) { ", version >= $($d.MinVersion)" })" } 'Registry' { "DisplayName $($d.MatchMode.ToLower()) '$($d.DisplayName)'$(if ($d.MinVersion) { ", version >= $($d.MinVersion)" })" } 'File' { "$($d.FilePath)$(if ($d.CheckFileVersion -and $d.MinVersion) { " version >= $($d.MinVersion)" })" } 'MSIX' { "Package $($d.PackageName)" } default { (("$($d.Script)" -split "`r?`n") | Where-Object { $_ -and $_ -notmatch '^\s*#' } | Select-Object -First 1) } }
    $db = switch ($d.Type) { 'MSI' { 'MSI product code' } 'Registry' { if ($entry) { 'Uninstall entry the installer created in Sandbox' } else { 'Guessed from the product name - not proven' } } 'File' { if ($PackageInput.Kind -eq 'Portable') { 'The copied program file' } else { 'Main program file the install created in Sandbox' } } 'MSIX' { 'Package identity' } default { 'Generated from what the install created in Sandbox' } }
    & $add 'Detection' $dv $db
    if (@($i.ProcessesToClose | Where-Object { "$_".Trim() }).Count -gt 0) { & $add 'Processes to close' (@($i.ProcessesToClose) -join ', ') 'Main program the install created; closed before upgrade / uninstall' }
    return $rows.ToArray()
}

function Invoke-AutoPackage
{
    # Drop anything -> a built, tested package. Reads the file, runs it in Windows Sandbox as SYSTEM to learn the silent
    # switches, uninstall and detection, builds the PSADT package, runs the package end to end in a fresh sandbox, and
    # writes AutoPackage-Report.md next to it.
    param
    (
        [Parameter(Mandatory)][string]$Path,
        $BaseDefinition,
        [string]$Destination,
        [switch]$NoSandbox,
        [switch]$SkipValidation,
        [switch]$Force,
        [int]$MaxAttempts = 4,
        [scriptblock]$ConfirmOverwrite,
        [scriptblock]$OnProgress            # called as (stage, message, definition or $null, installer info) at each step
    )
    $warnings = New-Object System.Collections.Generic.List[string]
    $notes    = New-Object System.Collections.Generic.List[string]
    $info     = $null
    $progress = { param($Stage, $Message, $Definition) if ($OnProgress) { & $OnProgress $Stage $Message $Definition $info } }
    $Path = (Resolve-Path -LiteralPath $Path).Path
    & $progress 'Reading' "Reading $(Split-Path -Path $Path -Leaf)..." $null
    $in = Resolve-PackageInput -Path $Path
    foreach ($n in @($in.Notes)) { $notes.Add($n) }
    Write-PackagerLog "Auto-package: $($in.Kind) $($in.Entry)"

    # Start clean, keeping the user's own settings.
    $def = New-PackageDefinition
    if ($BaseDefinition)
    {
        if ("$($BaseDefinition.App.Author)".Trim())          { $def.App.Author = $BaseDefinition.App.Author }
        if ("$($BaseDefinition.Output.Destination)".Trim())  { $def.Output.Destination = $BaseDefinition.Output.Destination }
        if ("$($BaseDefinition.Output.DeployMode)".Trim())   { $def.Output.DeployMode = $BaseDefinition.Output.DeployMode }
        if ("$($BaseDefinition.Output.IntuneWinAppUtil)".Trim()) { $def.Output.IntuneWinAppUtil = $BaseDefinition.Output.IntuneWinAppUtil }
        $def.Intune.TenantId = $BaseDefinition.Intune.TenantId
        $def.Intune.ClientId = $BaseDefinition.Intune.ClientId
    }
    if ($Destination) { $def.Output.Destination = $Destination }
    if (-not "$($def.Output.Destination)".Trim())
    {
        $saved = $null
        try { if (Test-Path -LiteralPath $script:SettingsPath) { $saved = (Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json).Destination } } catch { }
        $def.Output.Destination = $(if ("$saved".Trim()) { "$saved" } else { 'C:\Packages' })
    }
    $tool = Resolve-IntuneWinAppUtil -Configured $def.Output.IntuneWinAppUtil
    if (-not $tool)
    {
        try { $tool = Get-IntuneWinAppUtil } catch { $warnings.Add("IntuneWinAppUtil.exe could not be downloaded ($($_.Exception.Message)), so no .intunewin was built.") }
    }
    if ($tool) { $def.Output.IntuneWinAppUtil = $tool; $def.Output.BuildIntuneWin = $true } else { $def.Output.BuildIntuneWin = $false }

    # 1. What the file itself says.
    if ($in.Kind -eq 'Portable')
    {
        [void](Set-DefinitionForPortable -Def $def -PackageInput $in)
    }
    else
    {
        $info = Get-InstallerInfo -Path $in.Entry
        [void](Set-DefinitionFromInstaller -Def $def -Info $info)
        if ($in.IsFolder)
        {
            $def.Sources.Files = @($in.Root.TrimEnd('\') + '\*')
            $def.Install.File  = $in.EntryRelative
        }
        if (@($in.Transforms).Count -gt 0) { $def.Install.Transforms = @($in.Transforms); $notes.Add("Transforms applied: $(@($in.Transforms) -join ', ')") }
        if ($in.UninstallScript)
        {
            $def.Uninstall.Type = 'Script'
            $def.Uninstall.File = $in.UninstallScript
            $notes.Add("Uses the shipped uninstall script $($in.UninstallScript).")
        }
        $split = Split-NameAndVersion $in.NameHint
        if ($in.Kind -eq 'Script' -or -not "$($def.App.Name)".Trim()) { $def.App.Name = Get-CleanAppName -Name $split.Name -Version $split.Version }
        if (-not "$($def.App.Version)".Trim() -and $split.Version) { $def.App.Version = $split.Version }
    }
    $what = "$("$($def.App.Name) $($def.App.Version)".Trim())"
    $next = switch ($in.Kind)
    {
        'EXE'      { "Read the installer: $what ($($script:SilentPresets[$info.Engine].Label)). Next: find its silent switches in Windows Sandbox." }
        'MSI'      { "Read the MSI: $what. An MSI describes itself, so there are no switches to discover. Next: build and test it." }
        'MSIX'     { "Read the package: $what. Next: build and test it." }
        'Script'   { "Read the script: $what. Next: run it in Windows Sandbox to see what it installs." }
        'Portable' { "No installer, so $what will be copied to Program Files with a Start menu shortcut. Next: build and test it." }
    }
    & $progress 'Read' $next $def

    # 2. What running it shows (installers and scripts; MSI and MSIX are fully described by the file).
    $probe = @(); $win = $null
    $sandbox = $false
    if (-not $NoSandbox) { $sandbox = [bool](Test-WindowsSandbox) }
    if (-not $NoSandbox -and -not $sandbox) { $warnings.Add('Windows Sandbox is not available, so nothing was run: switches, uninstall and detection are educated guesses.') }
    if ($sandbox -and $in.Kind -in @('EXE', 'Script'))
    {
        if ($in.Kind -eq 'EXE')
        {
            $candidates = @(Get-SilentCandidates -Path $in.Entry -Engine $info.Engine -CurrentArgs $info.InstallArgs -Max $MaxAttempts)
            $detGuess   = New-DetectionScript -Def $def
            $uArgs      = "$($info.UninstallArgs)"
            $help       = '/?'
        }
        else
        {
            $candidates = @("$($def.Install.Arguments)")
            $detGuess   = $null
            $uArgs      = ''
            $help       = ''
        }
        $success = @(@($def.Install.SuccessExitCodes) + @($def.Install.RebootExitCodes) | ForEach-Object { [int]$_ })
        $entryLeaf = Split-Path -Path $in.Entry -Leaf
        $onAttempt = {
            param($Number, $Total, $Candidate)
            if ($in.Kind -eq 'Script') { & $progress 'Probing' "Running $entryLeaf as SYSTEM in Windows Sandbox to see what it creates..." $null }
            else { & $progress 'Probing' "Sandbox attempt $Number of ${Total}: running $entryLeaf $Candidate as SYSTEM. Installers that contain MSIs pause about 2 minutes per MSI in the sandbox." $null }
        }
        $probe = @(Invoke-SandboxProbe -InstallerPath $in.Entry -SourceRoot $in.Root -CopyWholeSource:$in.IsFolder -Candidates $candidates -DetectionScript $detGuess -UninstallArgs $uArgs -AppNameHint $def.App.Name -SuccessCodes $success -HelpSwitch $help -OnAttempt $onAttempt)
        $win = @($probe | Where-Object { $_.InstallSucceeded }) | Select-Object -First 1
        if ($win)
        {
            [void](Set-DefinitionFromProbe -Def $def -Result $win -Auto -NameHint $in.NameHint)
            & $progress 'Probed' $(if ($in.Kind -eq 'Script') { 'The script ran cleanly. Detection and uninstall were worked out from what it created.' } else { "Installs silently with '$($win.Candidate)'. Uninstall and detection were worked out from what it created." }) $def
            $perUser = @($win.Footprint.PerUser) + @($win.NewEntries | Where-Object { $_.Location -like 'CurrentUser*' } | ForEach-Object { "uninstall entry $($_.DisplayName) in HKCU" })
            if (@($perUser | Where-Object { $_ }).Count -gt 0)
            {
                $warnings.Add("This is a per-user installer: run as SYSTEM it installed into the system profile ($(@($perUser) -join '; ')), which no user sees. Look for a machine-wide installer (many vendors ship an MSI), or deploy it in the user context.")
            }
            if ($win.Uninstall -and -not $win.Uninstall.Verified -and $def.Uninstall.Type -eq 'Name') { $warnings.Add("The registered uninstall command did not prove silent in Sandbox ($(if ($win.Uninstall.Stuck) { $win.Uninstall.Stuck } elseif (-not $win.Uninstall.EntryRemoved) { 'the uninstall entry was still there afterwards' } else { 'detection still found the app' })). The package uninstalls by name instead; check it.") }
        }
        else
        {
            if ($in.Kind -eq 'Script')
            {
                $warnings.Add("The script did not run cleanly in Windows Sandbox: $((Get-ProbeFailureReason -Result @($probe)[0] -SuccessCodes $success).TrimEnd('.')). Detection and uninstall could not be worked out; set them on the tabs.")
            }
            else
            {
                $why = (@($probe | ForEach-Object { "[$($_.Candidate)] $(Get-ProbeFailureReason -Result $_ -SuccessCodes $success)" })) -join '; '
                $warnings.Add("No silent install was found: $why. Check the help text in this report, enter the right switches on the Install tab and run 'Find switches in Sandbox' again.")
            }
        }
    }

    # 3. Build.
    if (-not "$($def.App.Version)".Trim()) { $def.App.Version = '1.0.0'; $warnings.Add('No version found anywhere; used 1.0.0. Set the real version on the Application tab.') }
    $context = [pscustomobject]@{
        Status = 'NeedsAttention'; InputPath = $Path; Input = $in; Info = $info; Definition = $def; Probe = $probe; Validation = $null
        ValidationNote = ''; Warnings = $warnings; Notes = $notes; Decisions = @(); PackageRoot = $null; ReportPath = $null
    }
    $problems = Test-PackageDefinition -Def $def
    if ($problems.Count -gt 0)
    {
        foreach ($p in $problems) { $warnings.Add("Not built: $p") }
        $context.Decisions = Get-AutoDecisions -Def $def -PackageInput $in -Info $info -Win $win -Attempts @($probe).Count -WinAttempt ([Array]::IndexOf(@($probe), $win) + 1)
        Write-PackagerLog ('Auto-package stopped before building: ' + ($problems -join ' ')) -Level Warn
        return $context
    }
    $paths = Get-PackagePaths -Def $def
    $overwrite = [bool]$Force
    if ((Test-Path -LiteralPath $paths.Package) -and -not $overwrite)
    {
        if ($ConfirmOverwrite -and (& $ConfirmOverwrite $paths.Root)) { $overwrite = $true }
        else { throw "A package already exists at $($paths.Root). Use -Force (or confirm) to rebuild it." }
    }
    & $progress 'Building' 'Building the PSADT package and .intunewin...' $null
    $root = Invoke-PackageBuild -Def $def -Force:$overwrite
    $context.PackageRoot = $root

    # 4. Prove the package itself.
    if ($SkipValidation) { $context.ValidationNote = 'Skipped on request.' }
    elseif (-not $sandbox) { $context.ValidationNote = $(if ($NoSandbox) { 'Sandbox runs were turned off (-NoSandbox).' } else { 'Windows Sandbox is not available.' }) }
    elseif ($in.Kind -in @('EXE', 'Script') -and -not $win) { $context.ValidationNote = 'Skipped: no silent install was found, so the package would only hang.' }
    else
    {
        $codes = @(@($def.Install.SuccessExitCodes) + @($def.Install.RebootExitCodes) | ForEach-Object { [int]$_ })
        & $progress 'Validating' 'Testing the finished package in a fresh Windows Sandbox as SYSTEM: install, detect, uninstall, detect again...' $null
        $context.Validation = Invoke-SandboxValidation -PackageRoot $root -DetectName $paths.DetectName -SuccessCodes $codes
        if (-not $context.Validation) { $context.ValidationNote = 'The sandbox returned no result; see the run folder under %LOCALAPPDATA%\PsadtPackager\Sandbox.' }
        elseif ($context.Validation.Error -and -not $context.Validation.Validation) { $context.ValidationNote = "The sandbox reported: $($context.Validation.Error)" }
    }

    $v = $null
    if ($context.Validation) { $v = $context.Validation.Validation }
    if ($v -and -not $v.Passed)
    {
        $failed = @()
        if (-not $v.InstallOk) { $failed += 'the install failed' }
        if (-not $v.DetectAfterInstall.Detected) { $failed += 'detection did not find the app after install' }
        if (-not $v.UninstallOk) { $failed += 'the uninstall failed' }
        if ($v.DetectAfterUninstall.Detected) { $failed += 'detection still found the app after uninstall' }
        $warnings.Add("End-to-end test failed: $($failed -join ', '). The toolkit logs are in Validation\.")
    }
    $hardProblem = ($warnings | Where-Object { $_ -match '^(No silent install|The script did not run cleanly|End-to-end test failed|This is a per-user installer|Not built)' }).Count -gt 0
    if ($v -and $v.Passed -and -not $hardProblem) { $context.Status = 'Validated' }
    elseif (-not $hardProblem) { $context.Status = 'Built' }
    else { $context.Status = 'NeedsAttention' }

    $context.Decisions = Get-AutoDecisions -Def $def -PackageInput $in -Info $info -Win $win -Attempts @($probe).Count -WinAttempt ([Array]::IndexOf(@($probe), $win) + 1)
    $reportPath = Join-Path $root 'AutoPackage-Report.md'
    Write-Utf8File -Path $reportPath -Content (New-AutoPackageReport -Context $context)
    $context.ReportPath = $reportPath
    Write-PackagerLog "Auto-package finished: $($context.Status). Report: $reportPath"
    return $context
}

#endregion

#region ---------------------------------------------------------------- Intune: command lines, app payload, Graph publishing

function Get-PackagePaths
{
    # Every generated path is derived from the definition, so a package can be published later without rebuilding.
    param([Parameter(Mandatory)]$Def)
    # [IO.Path]::Combine, not Join-Path: this only builds strings and must not touch the
    # provider (Join-Path fails on a drive that is not currently mapped).
    $folderName = Get-PackageFolderName -Def $Def
    $root       = [System.IO.Path]::Combine("$($Def.Output.Destination)", $folderName)
    $detectName = "Detect-$(Get-SafeName $Def.App.Name).ps1"
    $winName    = "$folderName.intunewin"
    return [pscustomobject]@{
        FolderName   = $folderName
        Root         = $root
        Package      = [System.IO.Path]::Combine($root, 'Package')
        FilesDir     = [System.IO.Path]::Combine($root, 'Package', 'Files')
        SupportDir   = [System.IO.Path]::Combine($root, 'Package', 'SupportFiles')
        DetectName   = $detectName
        DetectScript = [System.IO.Path]::Combine($root, $detectName)
        IntuneDir    = [System.IO.Path]::Combine($root, 'Intune')
        IntuneWinName= $winName
        IntuneWin    = [System.IO.Path]::Combine($root, 'Intune', $winName)
    }
}

function Get-DeployModeArgument
{
    param([Parameter(Mandatory)]$Def)
    $mode = if ($script:DeployModeChoices -contains $Def.Output.DeployMode) { $Def.Output.DeployMode } else { 'Silent' }
    if ($mode -eq 'Auto') { return '' }
    return " -DeployMode $mode"
}

function Get-IntuneInstallCommand
{
    # The Intune "Install command". Blank override = derived from the deploy mode.
    param([Parameter(Mandatory)]$Def)
    $override = "$($Def.Intune.InstallCommand)".Trim()
    if ($override) { return $override }
    return "Invoke-AppDeployToolkit.exe -DeploymentType Install$(Get-DeployModeArgument -Def $Def)"
}

function Get-IntuneUninstallCommand
{
    param([Parameter(Mandatory)]$Def)
    $override = "$($Def.Intune.UninstallCommand)".Trim()
    if ($override) { return $override }
    return "Invoke-AppDeployToolkit.exe -DeploymentType Uninstall$(Get-DeployModeArgument -Def $Def)"
}

function Get-IntuneDisplayName
{
    param([Parameter(Mandatory)]$Def)
    $override = "$($Def.Intune.DisplayName)".Trim()
    if ($override) { return $override }
    return (@("$($Def.App.Name)".Trim(), "$($Def.App.Version)".Trim()) | Where-Object { $_ }) -join ' '
}

function Get-IntuneArchitectures
{
    # applicableArchitectures. An x86 package is normally allowed to run on x64 too.
    param([Parameter(Mandatory)]$Def)
    $override = "$($Def.Intune.Architecture)".Trim()
    if ($override) { return $override }
    switch ("$($Def.App.Arch)".Trim().ToLowerInvariant())
    {
        'x64'   { return 'x64' }
        'x86'   { return 'x86,x64' }
        'arm64' { return 'arm64' }
        default { return 'x86,x64' }
    }
}

function Get-IntuneReturnCodes
{
    # Success / reboot codes come from the Install tab; the rest are the standard PSADT and Windows Installer codes.
    param([Parameter(Mandatory)]$Def)
    $ordered = New-Object System.Collections.Generic.List[object]
    $pairs   = New-Object System.Collections.Generic.List[object]

    foreach ($c in @($Def.Install.SuccessExitCodes | Where-Object { "$_" -match '^-?\d+$' })) { $pairs.Add(@([int]$c, 'success')) }
    $pairs.Add(@(0, 'success'))
    $pairs.Add(@(1707, 'success'))
    foreach ($c in @($Def.Install.RebootExitCodes | Where-Object { "$_" -match '^-?\d+$' }))
    {
        if ([int]$c -eq 1641) { $pairs.Add(@(1641, 'hardReboot')) } else { $pairs.Add(@([int]$c, 'softReboot')) }
    }
    $pairs.Add(@(1618, 'retry'))    # another installation is already in progress
    $pairs.Add(@(60012, 'retry'))   # PSADT: user deferred the install
    $pairs.Add(@(1602, 'failed'))   # user cancelled

    $seen = @{}
    foreach ($pair in $pairs)
    {
        $code = [int]$pair[0]
        if ($seen.ContainsKey($code)) { continue }
        $seen[$code] = $true
        $ordered.Add([ordered]@{ returnCode = $code; type = "$($pair[1])" })
    }
    # ToArray(), not ,@($ordered): the unary comma cannot wrap a generic List.
    return ,$ordered.ToArray()
}

function New-IntuneAppPayload
{
    # Builds the #microsoft.graph.win32LobApp body, filling everything the definition already knows.
    param
    (
        [Parameter(Mandatory)]$Def,
        [Parameter(Mandatory)][string]$DetectionScript,
        [string]$IntuneWinFileName
    )
    $a  = $Def.App
    $it = $Def.Intune

    $publisher = "$($it.Publisher)".Trim()
    if (-not $publisher) { $publisher = "$($a.Vendor)".Trim() }
    if (-not $publisher) { $publisher = 'Unknown' }

    $description = "$($it.Description)".Trim()
    if (-not $description)
    {
        $description = (@("$($a.Vendor)".Trim(), "$($a.Name)".Trim(), "$($a.Version)".Trim()) | Where-Object { $_ }) -join ' '
        $description += ", packaged with PSAppDeployToolkit."
    }

    $notes = "$($it.Notes)".Trim()
    if (-not $notes)
    {
        $notes = "Generated by PSADT Packager $script:PackagerVersion on $(Get-Date -Format 'yyyy-MM-dd'). Rebuild from Package.json."
    }

    $developer = "$($it.Developer)".Trim(); if (-not $developer) { $developer = "$($a.Vendor)".Trim() }
    $owner     = "$($it.Owner)".Trim();     if (-not $owner)     { $owner     = "$($a.Author)".Trim() }

    $minOs = if ($script:MinOsCodes -contains "$($it.MinimumOs)") { "$($it.MinimumOs)" } else { 'v10_1809' }
    $os = [ordered]@{ '@odata.type' = 'microsoft.graph.windowsMinimumOperatingSystem' }
    $os[$minOs] = $true

    $runAs = if ($script:RunAsChoices -contains "$($it.RunAsAccount)") { "$($it.RunAsAccount)" } else { 'system' }
    $restart = if ($script:RestartChoices -contains "$($it.RestartBehavior)") { "$($it.RestartBehavior)" } else { 'basedOnReturnCode' }
    $maxRun = if ("$($it.MaxRunTimeInMinutes)" -match '^\d+$' -and [int]$it.MaxRunTimeInMinutes -gt 0) { [int]$it.MaxRunTimeInMinutes } else { 60 }

    $scriptBytes = [System.Text.Encoding]::UTF8.GetBytes($DetectionScript)

    $payload = [ordered]@{
        '@odata.type'                = '#microsoft.graph.win32LobApp'
        displayName                  = Get-IntuneDisplayName -Def $Def
        description                  = $description
        publisher                    = $publisher
        developer                    = $developer
        owner                        = $owner
        notes                        = $notes
        informationUrl               = "$($it.InformationUrl)".Trim()
        privacyInformationUrl        = "$($it.PrivacyUrl)".Trim()
        isFeatured                   = $false
        displayVersion               = "$($a.Version)".Trim()
        fileName                     = $(if ($IntuneWinFileName) { $IntuneWinFileName } else { (Get-PackagePaths -Def $Def).IntuneWinName })
        setupFilePath                = 'Invoke-AppDeployToolkit.exe'
        installCommandLine           = Get-IntuneInstallCommand -Def $Def
        uninstallCommandLine         = Get-IntuneUninstallCommand -Def $Def
        applicableArchitectures      = Get-IntuneArchitectures -Def $Def
        allowAvailableUninstall      = [bool]$it.AllowAvailableUninstall
        minimumSupportedOperatingSystem = $os
        msiInformation               = $null
        installExperience            = [ordered]@{
            '@odata.type'         = 'microsoft.graph.win32LobAppInstallExperience'
            runAsAccount          = $runAs
            deviceRestartBehavior = $restart
            maxRunTimeInMinutes   = $maxRun
        }
        returnCodes                  = Get-IntuneReturnCodes -Def $Def
        detectionRules               = @(
            [ordered]@{
                '@odata.type'         = '#microsoft.graph.win32LobAppPowerShellScriptDetection'
                enforceSignatureCheck = $false
                runAs32Bit            = $false
                scriptContent         = [Convert]::ToBase64String($scriptBytes)
            }
        )
    }
    return $payload
}

function ConvertTo-IntuneAppJson
{
    param([Parameter(Mandatory)]$Payload)
    return ($Payload | ConvertTo-Json -Depth 12)
}

#region ---- Graph authentication (device code, no modules required)

function Get-JwtPayload
{
    param([string]$Token)
    try
    {
        $part = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
        return ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json)
    }
    catch { return $null }
}

function Connect-IntuneGraph
{
    # Device code flow against the Microsoft Graph PowerShell public client (or your own app registration).
    param
    (
        [string]$TenantId = 'organizations',
        [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e',
        [switch]$Silent
    )
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    if (-not "$TenantId".Trim()) { $TenantId = 'organizations' }
    if (-not "$ClientId".Trim()) { $ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e' }
    $scope = 'https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All offline_access openid profile'
    $authority = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0"

    $dc = Invoke-RestMethod -Method Post -Uri "$authority/devicecode" -Body @{ client_id = $ClientId; scope = $scope } -ErrorAction Stop
    Write-PackagerLog "Sign in at $($dc.verification_uri) with code $($dc.user_code)"
    if (-not $Silent)
    {
        try { Set-Clipboard -Value $dc.user_code -ErrorAction SilentlyContinue } catch { }
        try { Start-Process $dc.verification_uri } catch { }
    }
    if ($script:GraphPromptSink) { & $script:GraphPromptSink $dc }

    $deadline = (Get-Date).AddSeconds([int]$dc.expires_in)
    $interval = [Math]::Max(3, [int]$dc.interval)
    while ((Get-Date) -lt $deadline)
    {
        Start-Sleep -Seconds $interval
        try
        {
            $tok = Invoke-RestMethod -Method Post -Uri "$authority/token" -ErrorAction Stop -Body @{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = $ClientId
                device_code = $dc.device_code
            }
            $claims = Get-JwtPayload -Token $tok.access_token
            $script:GraphToken = [pscustomobject]@{
                AccessToken  = $tok.access_token
                RefreshToken = $tok.refresh_token
                ExpiresOn    = (Get-Date).AddSeconds([int]$tok.expires_in - 300)
                TenantId     = $(if ($claims) { $claims.tid } else { $TenantId })
                ClientId     = $ClientId
                Account      = $(if ($claims) { @($claims.upn, $claims.unique_name, $claims.preferred_username) | Where-Object { $_ } | Select-Object -First 1 } else { '' })
            }
            Write-PackagerLog "Connected to Graph as $($script:GraphToken.Account) (tenant $($script:GraphToken.TenantId))"
            return $script:GraphToken
        }
        catch
        {
            $body = $null
            try { $body = ($_.ErrorDetails.Message | ConvertFrom-Json) } catch { }
            $code = if ($body) { "$($body.error)" } else { '' }
            if ($code -eq 'authorization_pending') { continue }
            if ($code -eq 'slow_down') { $interval += 5; continue }
            if ($code -eq 'authorization_declined') { throw 'Sign-in was declined.' }
            if ($code -eq 'expired_token') { throw 'The device code expired before sign-in completed.' }
            if ($code) { throw "Sign-in failed: $code - $($body.error_description)" }
            throw
        }
    }
    throw 'Timed out waiting for sign-in.'
}

function Get-GraphAccessToken
{
    if (-not $script:GraphToken) { throw 'Not connected to Microsoft Graph. Use Connect on the Intune tab first.' }
    if ((Get-Date) -lt $script:GraphToken.ExpiresOn) { return $script:GraphToken.AccessToken }
    if ($script:GraphToken.RefreshToken)
    {
        try
        {
            $authority = "https://login.microsoftonline.com/$($script:GraphToken.TenantId)/oauth2/v2.0"
            $tok = Invoke-RestMethod -Method Post -Uri "$authority/token" -ErrorAction Stop -Body @{
                grant_type    = 'refresh_token'
                client_id     = $script:GraphToken.ClientId
                refresh_token = $script:GraphToken.RefreshToken
                scope         = 'https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All offline_access'
            }
            $script:GraphToken.AccessToken  = $tok.access_token
            $script:GraphToken.ExpiresOn    = (Get-Date).AddSeconds([int]$tok.expires_in - 300)
            if ($tok.refresh_token) { $script:GraphToken.RefreshToken = $tok.refresh_token }
            return $script:GraphToken.AccessToken
        }
        catch { throw "The Graph token expired and could not be refreshed: $($_.Exception.Message). Connect again." }
    }
    throw 'The Graph token expired. Connect again on the Intune tab.'
}

function Invoke-GraphApi
{
    param
    (
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        $Body,
        [int]$Retries = 4
    )
    if ($Uri -notmatch '^https?://') { $Uri = "https://graph.microsoft.com/beta$Uri" }
    $headers = @{ Authorization = "Bearer $(Get-GraphAccessToken)"; Accept = 'application/json' }
    $json = $null
    if ($null -ne $Body) { $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 } }

    for ($attempt = 0; $attempt -le $Retries; $attempt++)
    {
        try
        {
            if ($null -ne $json)
            {
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json' -ErrorAction Stop
            }
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ErrorAction Stop
        }
        catch
        {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($attempt -lt $Retries -and ($status -eq 429 -or $status -ge 500))
            {
                $wait = [Math]::Pow(2, $attempt) * 2
                Write-PackagerLog "Graph returned $status; retrying in $wait s" -Level Warn
                Start-Sleep -Seconds $wait
                continue
            }
            $detail = ''
            try { $detail = $_.ErrorDetails.Message } catch { }
            if (-not $detail)
            {
                try
                {
                    $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $detail = $sr.ReadToEnd(); $sr.Dispose()
                }
                catch { }
            }
            throw "Graph $Method $Uri failed ($status): $($_.Exception.Message)$(if ($detail) { "`n$detail" })"
        }
    }
}

#endregion

#region ---- .intunewin inspection and content upload

function Read-IntuneWinPackage
{
    # A .intunewin is a zip: Metadata\Detection.xml describes the already-encrypted payload in Contents\.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExtractTo)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Package not found: $Path" }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try
    {
        $metaEntry = $zip.Entries | Where-Object { $_.FullName -eq 'IntuneWinPackage/Metadata/Detection.xml' } | Select-Object -First 1
        if (-not $metaEntry) { throw "$Path does not contain IntuneWinPackage\Metadata\Detection.xml - rebuild it with IntuneWinAppUtil." }
        $sr = New-Object System.IO.StreamReader($metaEntry.Open())
        try { [xml]$meta = $sr.ReadToEnd() } finally { $sr.Dispose() }

        $contentEntry = $zip.Entries | Where-Object { $_.FullName -eq 'IntuneWinPackage/Contents/IntunePackage.intunewin' } | Select-Object -First 1
        if (-not $contentEntry) { throw "$Path does not contain the encrypted payload." }
        if (Test-Path -LiteralPath $ExtractTo) { Remove-Item -LiteralPath $ExtractTo -Force }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($contentEntry, $ExtractTo, $true)

        $info = $meta.ApplicationInfo
        $enc  = $info.EncryptionInfo
        return [pscustomobject]@{
            Name              = "$($info.Name)"
            FileName          = "$($info.FileName)"
            SetupFile         = "$($info.SetupFile)"
            UnencryptedSize   = [int64]"$($info.UnencryptedContentSize)"
            EncryptedFilePath = $ExtractTo
            EncryptedSize     = (Get-Item -LiteralPath $ExtractTo).Length
            EncryptionInfo    = [ordered]@{
                encryptionKey        = "$($enc.EncryptionKey)"
                macKey               = "$($enc.MacKey)"
                initializationVector = "$($enc.InitializationVector)"
                mac                  = "$($enc.Mac)"
                profileIdentifier    = 'ProfileVersion1'
                fileDigest           = "$($enc.FileDigest)"
                fileDigestAlgorithm  = "$($enc.FileDigestAlgorithm)"
            }
        }
    }
    finally { $zip.Dispose() }
}

function Set-IntuneWinDisplayName
{
    # The Add App wizard prefills Name and Description from <Name> in Metadata\Detection.xml.
    # IntuneWinAppUtil sets it to the setup file, so every PSADT package would show up as
    # 'Invoke-AppDeployToolkit.exe'. Detection.xml is a plain zip entry outside the encrypted payload.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $entryName = 'IntuneWinPackage/Metadata/Detection.xml'
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Update)
    try
    {
        $entry = $zip.GetEntry($entryName)
        if (-not $entry) { throw "$Path has no $entryName" }
        $sr = New-Object System.IO.StreamReader($entry.Open())
        try { [xml]$meta = $sr.ReadToEnd() } finally { $sr.Dispose() }
        $meta.ApplicationInfo.Name = $Name
        $entry.Delete()
        $entry  = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
        $stream = $entry.Open()
        try
        {
            $settings = New-Object System.Xml.XmlWriterSettings
            $settings.Indent   = $true
            $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
            $writer = [System.Xml.XmlWriter]::Create($stream, $settings)
            try { $meta.Save($writer) } finally { $writer.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    finally { $zip.Dispose() }
}

function Wait-IntuneFileState
{
    param([Parameter(Mandatory)][string]$FileUri, [Parameter(Mandatory)][string]$State, [int]$TimeoutSeconds = 600)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline)
    {
        $file = Invoke-GraphApi -Uri $FileUri
        if ($file.uploadState -eq $State) { return $file }
        if ("$($file.uploadState)" -like '*Failed') { throw "Content upload failed (state: $($file.uploadState))." }
        Start-Sleep -Seconds 3
    }
    throw "Timed out waiting for upload state '$State'."
}

function Send-IntuneContentFile
{
    # Block-uploads the encrypted payload to the SAS URI Intune handed back.
    param
    (
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$SasUri,
        [Parameter(Mandatory)][string]$FileUri,
        [int]$BlockSizeMb = 4
    )
    Add-Type -AssemblyName System.Net.Http
    $blockSize = $BlockSizeMb * 1MB
    $total     = (Get-Item -LiteralPath $FilePath).Length
    $blockIds  = New-Object System.Collections.Generic.List[string]
    $client    = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $stream    = [System.IO.File]::OpenRead($FilePath)
    $renewedAt = Get-Date
    try
    {
        $buffer = New-Object byte[] $blockSize
        $index  = 0
        $sent   = [int64]0
        while (($read = $stream.Read($buffer, 0, $blockSize)) -gt 0)
        {
            $id = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($index.ToString('D6')))
            $blockIds.Add($id)

            # The SAS is short-lived; renew it well before it expires on large packages.
            if (((Get-Date) - $renewedAt).TotalMinutes -gt 25)
            {
                Write-PackagerLog 'Renewing the upload URI'
                [void](Invoke-GraphApi -Method POST -Uri "$FileUri/renewUpload" -Body @{})
                $file = Wait-IntuneFileState -FileUri $FileUri -State 'azureStorageUriRenewalSuccess'
                $SasUri = $file.azureStorageUri
                $renewedAt = Get-Date
            }

            $content = New-Object System.Net.Http.ByteArrayContent($buffer, 0, $read)
            $content.Headers.Add('x-ms-blob-type', 'BlockBlob')
            $uri = "$SasUri&comp=block&blockid=$([System.Uri]::EscapeDataString($id))"
            $resp = $client.PutAsync($uri, $content).GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode)
            {
                $err = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                throw "Block upload failed ($([int]$resp.StatusCode)): $err"
            }
            $sent += $read
            $index++
            if ($index % 5 -eq 0 -or $sent -eq $total)
            {
                Write-PackagerLog ("Uploaded {0:N1} MB of {1:N1} MB" -f ($sent / 1MB), ($total / 1MB))
            }
        }

        $xml = "<?xml version=`"1.0`" encoding=`"utf-8`"?><BlockList>" + (($blockIds | ForEach-Object { "<Latest>$_</Latest>" }) -join '') + '</BlockList>'
        $listContent = New-Object System.Net.Http.StringContent($xml, [System.Text.Encoding]::UTF8, 'text/plain')
        $resp = $client.PutAsync("$SasUri&comp=blocklist", $listContent).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode)
        {
            $err = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "Committing the block list failed ($([int]$resp.StatusCode)): $err"
        }
    }
    finally
    {
        $stream.Dispose()
        $client.Dispose()
    }
}

function Publish-IntuneWin32App
{
    # Creates the Win32 app, uploads the .intunewin and commits it.
    param
    (
        [Parameter(Mandatory)]$Def,
        [string]$IntuneWinPath,
        [string]$DetectionScript
    )
    $paths = Get-PackagePaths -Def $Def
    if (-not $IntuneWinPath) { $IntuneWinPath = $paths.IntuneWin }
    if (-not (Test-Path -LiteralPath $IntuneWinPath -PathType Leaf))
    {
        throw "No .intunewin at $IntuneWinPath. Tick 'Build .intunewin' on the Build tab and generate the package first."
    }
    if (-not $DetectionScript)
    {
        if (Test-Path -LiteralPath $paths.DetectScript -PathType Leaf) { $DetectionScript = [System.IO.File]::ReadAllText($paths.DetectScript) }
        else { $DetectionScript = New-DetectionScript -Def $Def }
    }

    $temp = Join-Path $env:TEMP ("PsadtPackager-{0}.bin" -f [guid]::NewGuid().ToString('N'))
    try
    {
        Write-PackagerLog "Reading $IntuneWinPath"
        $pkg = Read-IntuneWinPackage -Path $IntuneWinPath -ExtractTo $temp

        $payload = New-IntuneAppPayload -Def $Def -DetectionScript $DetectionScript -IntuneWinFileName (Split-Path -Path $IntuneWinPath -Leaf)

        $existing = $null
        try
        {
            $escaped = "$($payload.displayName)".Replace("'", "''")
            $found = Invoke-GraphApi -Uri "/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp') and displayName eq '$escaped'"
            $existing = @($found.value) | Select-Object -First 1
        }
        catch { }
        if ($existing) { Write-PackagerLog "An app named '$($payload.displayName)' already exists (id $($existing.id)); creating a second one." -Level Warn }

        Write-PackagerLog "Creating Win32 app '$($payload.displayName)'"
        $app = Invoke-GraphApi -Method POST -Uri '/deviceAppManagement/mobileApps' -Body $payload
        Write-PackagerLog "App id $($app.id)"

        $appUri = "/deviceAppManagement/mobileApps/$($app.id)/microsoft.graph.win32LobApp"
        $version = Invoke-GraphApi -Method POST -Uri "$appUri/contentVersions" -Body @{}
        Write-PackagerLog "Content version $($version.id)"

        $fileBody = [ordered]@{
            '@odata.type'  = '#microsoft.graph.mobileAppContentFile'
            name           = $pkg.FileName
            size           = $pkg.UnencryptedSize
            sizeEncrypted  = $pkg.EncryptedSize
            manifest       = $null
            isDependency   = $false
        }
        $file = Invoke-GraphApi -Method POST -Uri "$appUri/contentVersions/$($version.id)/files" -Body $fileBody
        $fileUri = "$appUri/contentVersions/$($version.id)/files/$($file.id)"

        Write-PackagerLog 'Waiting for the upload URI'
        $file = Wait-IntuneFileState -FileUri $fileUri -State 'azureStorageUriRequestSuccess'

        Write-PackagerLog ("Uploading {0:N1} MB" -f ($pkg.EncryptedSize / 1MB))
        Send-IntuneContentFile -FilePath $pkg.EncryptedFilePath -SasUri $file.azureStorageUri -FileUri $fileUri

        Write-PackagerLog 'Committing the file'
        [void](Invoke-GraphApi -Method POST -Uri "$fileUri/commit" -Body @{ fileEncryptionInfo = $pkg.EncryptionInfo })
        [void](Wait-IntuneFileState -FileUri $fileUri -State 'commitFileSuccess')

        [void](Invoke-GraphApi -Method PATCH -Uri "/deviceAppManagement/mobileApps/$($app.id)" -Body @{
            '@odata.type'           = '#microsoft.graph.win32LobApp'
            committedContentVersion = "$($version.id)"
        })

        $portal = "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$($app.id)"
        Write-PackagerLog "Published. Assignments are not set - open $portal"
        return [pscustomobject]@{ Id = $app.id; DisplayName = $payload.displayName; PortalUrl = $portal }
    }
    finally
    {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

#endregion

#endregion

#region ---------------------------------------------------------------- Headless entry point

if ($NoGui)
{
    if (-not $Definition -and -not $InstallerPath) { throw 'Specify -Definition <Package.json> or -InstallerPath <installer, script, zip or folder> with -NoGui.' }
    if ($InstallerPath)
    {
        try
        {
            # Saved GUI settings (author, destination, tool path, tenant) apply to headless runs too.
            $base = New-PackageDefinition
            try
            {
                if (Test-Path -LiteralPath $script:SettingsPath)
                {
                    $saved = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
                    if ($saved.Author)           { $base.App.Author = "$($saved.Author)" }
                    if ($saved.Destination)      { $base.Output.Destination = "$($saved.Destination)" }
                    if ($saved.IntuneWinAppUtil) { $base.Output.IntuneWinAppUtil = "$($saved.IntuneWinAppUtil)" }
                    if ($saved.TenantId)         { $base.Intune.TenantId = "$($saved.TenantId)" }
                    if ($saved.ClientId)         { $base.Intune.ClientId = "$($saved.ClientId)" }
                }
            }
            catch { }
            if ($TenantId) { $base.Intune.TenantId = $TenantId }
            if ($ClientId) { $base.Intune.ClientId = $ClientId }
            $ctx = Invoke-AutoPackage -Path $InstallerPath -BaseDefinition $base -Destination $Destination -NoSandbox:$NoSandbox -SkipValidation:$SkipValidation -Force:$Force
            foreach ($w in @($ctx.Warnings)) { Write-PackagerLog $w -Level Warn }
            Write-PackagerLog "Status: $($ctx.Status)$(if ($ctx.ReportPath) { " - $($ctx.ReportPath)" })"
            if (-not $ctx.PackageRoot) { exit 2 }
            if ($Publish)
            {
                if ($ctx.Status -eq 'NeedsAttention') { Write-PackagerLog 'Not publishing: the package needs attention (see the report).' -Level Warn }
                else
                {
                    [void](Connect-IntuneGraph -TenantId $ctx.Definition.Intune.TenantId -ClientId $ctx.Definition.Intune.ClientId -Silent)
                    $app = Publish-IntuneWin32App -Def $ctx.Definition
                    Write-PackagerLog "Intune app id $($app.Id)"
                }
            }
            Write-Output $ctx.PackageRoot
            if ($ctx.Status -eq 'NeedsAttention') { exit 2 }
            exit 0
        }
        catch
        {
            Write-PackagerLog -Message $_.Exception.Message -Level Error
            exit 1
        }
    }
    try
    {
        $def = Read-PackageDefinition -Path (Resolve-Path -LiteralPath $Definition).Path
        if ($Destination) { $def.Output.Destination = $Destination }
        if ($TenantId)    { $def.Intune.TenantId = $TenantId }
        if ($ClientId)    { $def.Intune.ClientId = $ClientId }
        if ($Publish -and -not $def.Output.BuildIntuneWin)
        {
            Write-PackagerLog 'Publishing needs a .intunewin; enabling the build step.' -Level Warn
            $def.Output.BuildIntuneWin = $true
        }
        $out = Invoke-PackageBuild -Def $def -Force:$Force
        if ($Publish -or $def.Intune.PublishAfterBuild)
        {
            [void](Connect-IntuneGraph -TenantId $def.Intune.TenantId -ClientId $def.Intune.ClientId -Silent)
            $app = Publish-IntuneWin32App -Def $def
            Write-PackagerLog "Intune app id $($app.Id)"
        }
        Write-Output $out
        exit 0
    }
    catch
    {
        Write-PackagerLog -Message $_.Exception.Message -Level Error
        exit 1
    }
}

#endregion

#region ---------------------------------------------------------------- GUI

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA')
{
    # WPF needs an STA thread; relaunch this script in one.
    $exe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    # Quoted: the script or definition path may contain spaces (Documents, OneDrive, ...).
    $relaunchArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($Definition) { $relaunchArgs += @('-Definition', ('"{0}"' -f (Resolve-Path -LiteralPath $Definition).Path)) }
    if ($InstallerPath) { $relaunchArgs += @('-InstallerPath', ('"{0}"' -f (Resolve-Path -LiteralPath $InstallerPath).Path)) }
    if ($NoSandbox) { $relaunchArgs += '-NoSandbox' }
    if ($SkipValidation) { $relaunchArgs += '-SkipValidation' }
    Start-Process -FilePath $exe -ArgumentList $relaunchArgs
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# Our own app identity, set before any window exists: without it the taskbar groups this window under
# powershell.exe and shows PowerShell's icon. The MSI's Start menu shortcut carries the same ID, so the taskbar
# button, pinning and Alt+Tab all show PSADT Packager.
try
{
    Add-Type -Namespace PsadtPackager -Name Shell32 -MemberDefinition '[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);'
    [void][PsadtPackager.Shell32]::SetCurrentProcessExplicitAppUserModelID('YeomanLabs.PSADTPackager')
}
catch { }

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PSADT Packager" Width="1120" Height="900" MinWidth="980" MinHeight="760" AllowDrop="True"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13"
        Background="#F3F3F3" Foreground="#1B1B1B" UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <!-- Palette: YeomanLabs navy for primary actions and focus, coral for the selected tab and progress. -->
    <SolidColorBrush x:Key="Navy" Color="#041635"/>
    <SolidColorBrush x:Key="NavyHover" Color="#13305E"/>
    <SolidColorBrush x:Key="Focus" Color="#2A5BA0"/>
    <SolidColorBrush x:Key="Coral" Color="#FF6950"/>
    <SolidColorBrush x:Key="Line" Color="#E3E3E3"/>
    <SolidColorBrush x:Key="ControlLine" Color="#CFCFCF"/>
    <SolidColorBrush x:Key="Subtle" Color="#5F5F5F"/>

    <!-- The app mark (same drawing as PsadtPackager.ico): window icon when the .ico is not next to the script. -->
    <DrawingImage x:Key="AppIcon">
      <DrawingImage.Drawing>
        <DrawingGroup>
          <GeometryDrawing Brush="{StaticResource Navy}">
            <GeometryDrawing.Geometry>
              <RectangleGeometry Rect="8,8,240,240" RadiusX="52" RadiusY="52"/>
            </GeometryDrawing.Geometry>
          </GeometryDrawing>
          <GeometryDrawing Geometry="M 56 128 L 56 204 L 200 204 L 200 128 M 40 128 L 92 128 M 164 128 L 216 128">
            <GeometryDrawing.Pen>
              <Pen Brush="White" Thickness="18" StartLineCap="Round" EndLineCap="Round" LineJoin="Round"/>
            </GeometryDrawing.Pen>
          </GeometryDrawing>
          <GeometryDrawing Brush="{StaticResource Coral}" Geometry="M 110 40 L 146 40 L 146 112 L 178 112 L 128 168 L 78 112 L 110 112 Z"/>
          <GeometryDrawing Brush="Transparent" Geometry="M 0 0 L 256 256"/>
        </DrawingGroup>
      </DrawingImage.Drawing>
    </DrawingImage>

    <Style TargetType="Label">
      <Setter Property="Margin" Value="0,2,8,2"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Padding" Value="0,6,0,0"/>
      <Setter Property="Foreground" Value="#3A3A3A"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Background" Value="White"/>
      <Setter Property="Foreground" Value="#1B1B1B"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlLine}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,6"/>
      <Setter Property="Margin" Value="6,3,0,3"/>
      <Setter Property="MinWidth" Value="96"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#F7F7F7"/>
          <Setter Property="BorderBrush" Value="#B4B4B4"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="#ECECEC"/>
        </Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter Property="BorderBrush" Value="{StaticResource Focus}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Navy}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Navy}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{StaticResource NavyHover}"/>
          <Setter Property="BorderBrush" Value="{StaticResource NavyHover}"/>
        </Trigger>
        <Trigger Property="IsPressed" Value="True">
          <Setter Property="Background" Value="#020B1C"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Margin" Value="0,3,0,3"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlLine}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5">
              <ScrollViewer x:Name="PART_ContentHost" Focusable="False"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#A8A8A8"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Focus}"/>
                <Setter TargetName="Bd" Property="BorderThickness" Value="1,1,1,2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#F6F6F6"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#E2E2E2"/>
                <Setter Property="Foreground" Value="#9A9A9A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Code" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="AcceptsReturn" Value="True"/>
      <Setter Property="AcceptsTab" Value="True"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="TextWrapping" Value="NoWrap"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="VerticalContentAlignment" Value="Top"/>
    </Style>

    <!-- ComboBox: one template for both the drop-down list and the editable kind. -->
    <ControlTemplate x:Key="ComboToggle" TargetType="ToggleButton">
      <Border x:Name="Bd" Background="White" BorderBrush="{StaticResource ControlLine}" BorderThickness="1" CornerRadius="5">
        <Path x:Name="Arrow" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0"
              Data="M 0 0 L 4.5 4.5 L 9 0" Stroke="#5F5F5F" StrokeThickness="1.4" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter TargetName="Bd" Property="BorderBrush" Value="#A8A8A8"/>
        </Trigger>
        <Trigger Property="IsChecked" Value="True">
          <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource Focus}"/>
        </Trigger>
        <Trigger Property="IsEnabled" Value="False">
          <Setter TargetName="Bd" Property="Background" Value="#F6F6F6"/>
          <Setter TargetName="Bd" Property="BorderBrush" Value="#E2E2E2"/>
          <Setter TargetName="Arrow" Property="Stroke" Value="#B5B5B5"/>
        </Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate>

    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="0,3,0,3"/>
      <Setter Property="Padding" Value="8,5,30,5"/>
      <Setter Property="MinHeight" Value="29"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="Toggle" Template="{StaticResource ComboToggle}" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"/>
              <ContentPresenter x:Name="Selected" IsHitTestVisible="False" Margin="{TemplateBinding Padding}"
                                VerticalAlignment="Center" HorizontalAlignment="Left"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"/>
              <TextBox x:Name="PART_EditableTextBox" Style="{x:Null}" Visibility="Hidden" Margin="2,2,28,2" Padding="5,3"
                       VerticalContentAlignment="Center" Background="Transparent" BorderThickness="0"
                       IsReadOnly="{Binding IsReadOnly, RelativeSource={RelativeSource TemplatedParent}}"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="Slide"
                     IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Background="White" BorderBrush="#D6D6D6" BorderThickness="1" CornerRadius="6" Margin="0,4,0,0" Padding="3"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer>
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsEditable" Value="True">
                <Setter TargetName="PART_EditableTextBox" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Selected" Property="Visibility" Value="Hidden"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="#9A9A9A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F1F1F1"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E5ECF6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,7,18,4"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="4" BorderBrush="#8A8A8A" BorderThickness="1" Background="White" VerticalAlignment="Center">
                <Path x:Name="Mark" Data="M 3.5 9 L 7.3 12.6 L 14 5.4" Stroke="White" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Focus}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource Navy}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Navy}"/>
                <Setter TargetName="Mark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlLine}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="3">
              <ScrollViewer Focusable="False">
                <ItemsPresenter/>
              </ScrollViewer>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#F3F3F3"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#E5ECF6"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Thin scroll bars. -->
    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="T" Background="#BDBDBD" CornerRadius="3"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="T" Property="Background" Value="#959595"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="T" Property="Background" Value="#7A7A7A"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ScrollPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageUpCommand"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}" Margin="2,2"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageDownCommand"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageLeftCommand"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb Style="{StaticResource ScrollThumb}" Margin="2,2"/>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageRightCommand"/>
                    </Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Tabs: plain text with a coral bar under the selected one. -->
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabControl">
            <DockPanel>
              <Border DockPanel.Dock="Top" BorderBrush="#DEDEDE" BorderThickness="0,0,0,1" Margin="0,0,0,14">
                <TabPanel IsItemsHost="True" Background="Transparent"/>
              </Border>
              <ContentPresenter ContentSource="SelectedContent"/>
            </DockPanel>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Grid Background="Transparent" Margin="0,0,2,0">
              <ContentPresenter x:Name="Hdr" ContentSource="Header" Margin="14,8,14,11" TextElement.Foreground="#5F5F5F"/>
              <Border x:Name="Bar" Height="3" CornerRadius="1.5" Background="{StaticResource Coral}" VerticalAlignment="Bottom" Margin="14,0,14,-1" Visibility="Hidden"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Hdr" Property="TextElement.Foreground" Value="#1B1B1B"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bar" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Hdr" Property="TextElement.Foreground" Value="#1B1B1B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="White"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="22,18"/>
    </Style>

    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="4"/>
      <Setter Property="Foreground" Value="{StaticResource Coral}"/>
      <Setter Property="Background" Value="#E9E9E9"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <Style TargetType="GridSplitter">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="GridSplitter">
            <Grid Background="Transparent">
              <Border Width="44" Height="4" CornerRadius="2" Background="#CACACA" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Subtle}"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="LineHeight" Value="18"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="0,4,0,4"/>
    </Style>
  </Window.Resources>

  <DockPanel>
    <!-- Header -->
    <Border DockPanel.Dock="Top" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1" Padding="22,12,14,12">
      <DockPanel>
        <Menu DockPanel.Dock="Right" VerticalAlignment="Center" Background="Transparent" FontSize="13">
          <MenuItem Header="_File" Padding="10,5">
            <MenuItem Name="MenuNew" Header="_New definition"/>
            <MenuItem Name="MenuOpen" Header="_Open definition..."/>
            <MenuItem Name="MenuSave" Header="_Save definition"/>
            <MenuItem Name="MenuSaveAs" Header="Save definition _as..."/>
            <Separator/>
            <MenuItem Name="MenuExit" Header="E_xit"/>
          </MenuItem>
          <MenuItem Header="_Help" Padding="10,5">
            <MenuItem Name="MenuAbout" Header="_About"/>
          </MenuItem>
        </Menu>
        <Viewbox Width="36" Height="36" Margin="0,0,14,0" VerticalAlignment="Center">
          <Canvas Width="256" Height="256">
            <Rectangle Width="240" Height="240" Canvas.Left="8" Canvas.Top="8" RadiusX="52" RadiusY="52" Fill="{StaticResource Navy}"/>
            <Path Stroke="White" StrokeThickness="18" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                  Data="M 56 128 L 56 204 L 200 204 L 200 128 M 40 128 L 92 128 M 164 128 L 216 128"/>
            <Path Fill="{StaticResource Coral}" Data="M 110 40 L 146 40 L 146 112 L 178 112 L 128 168 L 78 112 L 110 112 Z"/>
          </Canvas>
        </Viewbox>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="PSADT Packager" FontSize="17" FontWeight="SemiBold"/>
          <TextBlock Text="PSAppDeployToolkit packages for Intune, worked out and tested in Windows Sandbox" Foreground="{StaticResource Subtle}" FontSize="12"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Status bar -->
    <Border DockPanel.Dock="Bottom" Background="White" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="22,7,22,7">
      <DockPanel>
        <ProgressBar Name="StatusProgress" DockPanel.Dock="Right" Width="180" IsIndeterminate="True" VerticalAlignment="Center" Visibility="Collapsed"/>
        <TextBlock Name="StatusText" Text="Ready" Foreground="{StaticResource Subtle}" TextTrimming="CharacterEllipsis" Margin="0,0,16,0"/>
      </DockPanel>
    </Border>

    <Grid Margin="22,14,22,14">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="14"/>
        <RowDefinition Height="160" MinHeight="70"/>
      </Grid.RowDefinitions>
      <TabControl Name="Tabs" Grid.Row="0">

        <TabItem Header="Application">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <!-- Drop zone: also shows progress and the result of an auto-package run. -->
              <Grid Name="DropZone" Margin="0,0,0,14">
                <Rectangle Name="DropZoneRect" RadiusX="10" RadiusY="10" Fill="White" Stroke="#B9B9B9" StrokeThickness="1.5" StrokeDashArray="5 4"/>
                <Grid Margin="26,22,26,22">
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Viewbox Width="54" Height="54" VerticalAlignment="Top" Margin="0,2,22,0">
                    <Canvas Width="256" Height="256">
                      <Rectangle Width="240" Height="240" Canvas.Left="8" Canvas.Top="8" RadiusX="52" RadiusY="52" Fill="#FFF1EE"/>
                      <Path Stroke="{StaticResource Navy}" StrokeThickness="18" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"
                            Data="M 56 128 L 56 204 L 200 204 L 200 128 M 40 128 L 92 128 M 164 128 L 216 128"/>
                      <Path Fill="{StaticResource Coral}" Data="M 110 40 L 146 40 L 146 112 L 178 112 L 128 168 L 78 112 L 110 112 Z"/>
                    </Canvas>
                  </Viewbox>
                  <StackPanel Grid.Column="1">
                    <TextBlock Name="DropTitle" Text="Drop an installer, script, .zip or folder here" FontSize="18" FontWeight="SemiBold" TextWrapping="Wrap"/>
                    <TextBlock Name="DropDetail" Style="{StaticResource Hint}" Margin="0,6,0,0"
                               Text="It runs in Windows Sandbox as SYSTEM to find the silent switches, uninstall and detection, builds the package and tests it end to end. The tabs fill in as it learns. .msi, .exe, .msix, .ps1, .cmd, .bat, .vbs, .zip or a folder."/>
                    <ProgressBar Name="DropProgress" IsIndeterminate="True" Margin="0,14,0,0" Visibility="Collapsed"/>
                    <TextBlock Name="DropElapsed" Foreground="{StaticResource Subtle}" FontSize="12" Margin="0,6,0,0" Visibility="Collapsed"/>
                    <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
                      <Button Name="BtnAutoPackage" Style="{StaticResource Primary}" Content="Auto-package a file..." Margin="0,0,0,0"
                              ToolTip="Pick an installer (.msi, .exe, .msix), script (.ps1, .cmd, .bat, .vbs) or .zip. Folders: drag them onto the window."/>
                      <Button Name="BtnOpenReport" Content="Open report" Margin="8,0,0,0" Visibility="Collapsed"/>
                      <Button Name="BtnImportInstaller" Content="Read metadata only..." Margin="8,0,0,0"
                              ToolTip="Only reads the file and fills the tabs for you to finish by hand; nothing is run."/>
                    </StackPanel>
                  </StackPanel>
                </Grid>
              </Grid>

              <Border Style="{StaticResource Card}">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <Label Grid.Row="0" Content="Vendor"/>
                  <TextBox Grid.Row="0" Grid.Column="1" Name="AppVendor"/>
                  <Label Grid.Row="1" Content="Application name"/>
                  <TextBox Grid.Row="1" Grid.Column="1" Name="AppName"/>
                  <Label Grid.Row="2" Content="Version"/>
                  <TextBox Grid.Row="2" Grid.Column="1" Name="AppVersion" Width="220" HorizontalAlignment="Left"/>
                  <Label Grid.Row="3" Content="Architecture"/>
                  <ComboBox Grid.Row="3" Grid.Column="1" Name="AppArch" Width="140" HorizontalAlignment="Left" IsEditable="True"/>
                  <Label Grid.Row="4" Content="Language"/>
                  <TextBox Grid.Row="4" Grid.Column="1" Name="AppLang" Width="80" HorizontalAlignment="Left"/>
                  <Label Grid.Row="5" Content="Revision"/>
                  <TextBox Grid.Row="5" Grid.Column="1" Name="AppRevision" Width="80" HorizontalAlignment="Left"/>
                  <Label Grid.Row="6" Content="Script version"/>
                  <TextBox Grid.Row="6" Grid.Column="1" Name="AppScriptVersion" Width="140" HorizontalAlignment="Left"/>
                  <Label Grid.Row="7" Content="Script author"/>
                  <TextBox Grid.Row="7" Grid.Column="1" Name="AppAuthor" Width="300" HorizontalAlignment="Left"/>
                  <TextBlock Grid.Row="8" Grid.Column="1" Style="{StaticResource Hint}" Margin="0,12,0,0"
                             Text="The output folder is named Vendor_Name_Version. Vendor, name and version also drive the PSADT dialog titles and log file names."/>
                </Grid>
              </Border>
            </StackPanel>
          </ScrollViewer>
        </TabItem>

        <TabItem Header="Source files">
          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Style="{StaticResource Hint}"
                         Text="Everything listed here is copied into the package. Files\ is for the installer, transforms, patches and scripts the deployment runs. SupportFiles\ is for anything else (config files, licences, fonts). 'Add folder contents' copies the files inside a folder; 'Add folder' copies the folder itself."/>
              <DockPanel Grid.Row="1">
                <TextBlock Style="{StaticResource Section}" Text="Files\" VerticalAlignment="Center"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button Name="BtnFilesAdd" Content="Add files..."/>
                  <Button Name="BtnFilesAddFolder" Content="Add folder..."/>
                  <Button Name="BtnFilesAddContents" Content="Add folder contents..."/>
                  <Button Name="BtnFilesRemove" Content="Remove selected"/>
                </StackPanel>
              </DockPanel>
              <ListBox Grid.Row="2" Name="FilesList" SelectionMode="Extended" FontFamily="Cascadia Mono, Consolas" FontSize="12" Margin="0,4,0,12"/>
              <DockPanel Grid.Row="3">
                <TextBlock Style="{StaticResource Section}" Text="SupportFiles\" VerticalAlignment="Center"/>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                  <Button Name="BtnSupportAdd" Content="Add files..."/>
                  <Button Name="BtnSupportAddFolder" Content="Add folder..."/>
                  <Button Name="BtnSupportAddContents" Content="Add folder contents..."/>
                  <Button Name="BtnSupportRemove" Content="Remove selected"/>
                </StackPanel>
              </DockPanel>
              <ListBox Grid.Row="5" Name="SupportList" SelectionMode="Extended" FontFamily="Cascadia Mono, Consolas" FontSize="12" Margin="0,4,0,0"/>
            </Grid>
          </Border>
        </TabItem>

        <TabItem Header="Install">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <Border Style="{StaticResource Card}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="180"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Style="{StaticResource Hint}"
                           Text="Defines the Install phase of Invoke-AppDeployToolkit.ps1 (Repair re-uses it). Pre/post PowerShell runs inside the toolkit session, so every *-ADT* function and $adtSession are available."/>
                <Label Grid.Row="1" Content="Install type"/>
                <ComboBox Grid.Row="1" Grid.Column="1" Name="InstallType" Width="380" HorizontalAlignment="Left"/>
                <Label Grid.Row="2" Content="Installer file"/>
                <DockPanel Grid.Row="2" Grid.Column="1">
                  <Button DockPanel.Dock="Right" Name="BtnInstallAutoFill" Content="Auto-fill from file"/>
                  <ComboBox Name="InstallFile" IsEditable="True"/>
                </DockPanel>
                <TextBlock Grid.Row="3" Grid.Column="1" Style="{StaticResource Hint}" Text="File name inside Files\ (pick from the list or type a relative path such as Setup\install.exe)."/>
                <Label Grid.Row="4" Content="Arguments"/>
                <DockPanel Grid.Row="4" Grid.Column="1">
                  <Button DockPanel.Dock="Right" Name="BtnProbeSandbox" Content="Find switches in Sandbox..." ToolTip="Runs the installer inside Windows Sandbox as SYSTEM with candidate silent switches, records what it creates and tests the uninstall. Nothing runs on this PC."/>
                  <ComboBox DockPanel.Dock="Right" Name="InstallPreset" Width="210" Margin="6,3,0,3"/>
                  <TextBox Name="InstallArgs" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
                </DockPanel>
                <TextBlock Grid.Row="5" Grid.Column="1" Style="{StaticResource Hint}" Name="InstallArgsHint" Text="EXE: silent switches. MSI: extra properties appended to the toolkit's /QN (e.g. ALLUSERS=1 ADDLOCAL=ALL). Script: parameters in PowerShell syntax."/>
                <Label Grid.Row="6" Content="MST transforms"/>
                <TextBox Grid.Row="6" Grid.Column="1" Name="InstallTransforms" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
                <Label Grid.Row="7" Content="MSI product code"/>
                <TextBox Grid.Row="7" Grid.Column="1" Name="InstallProductCode" FontFamily="Cascadia Mono, Consolas" FontSize="12" Width="380" HorizontalAlignment="Left"/>
                <Label Grid.Row="8" Content="Processes to close"/>
                <TextBox Grid.Row="8" Grid.Column="1" Name="CloseProcesses"/>
                <TextBlock Grid.Row="9" Grid.Column="1" Style="{StaticResource Hint}" Text="Comma-separated process names without .exe. Optional friendly name with a pipe: winword|Microsoft Word, excel|Microsoft Excel"/>
                <Label Grid.Row="10" Content="Exit codes"/>
                <StackPanel Grid.Row="10" Grid.Column="1" Orientation="Horizontal">
                  <Label Content="Success"/>
                  <TextBox Name="SuccessCodes" Width="160" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
                  <Label Content="Reboot" Margin="18,2,8,2"/>
                  <TextBox Name="RebootCodes" Width="160" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
                </StackPanel>
                <Label Grid.Row="11" Content="Dialogs"/>
                <WrapPanel Grid.Row="11" Grid.Column="1">
                  <CheckBox Name="ShowWelcome" Content="Welcome / close-apps dialog"/>
                  <CheckBox Name="AllowDefer" Content="Allow defer" Margin="0,7,8,4"/>
                  <TextBox Name="DeferTimes" Width="44" Margin="0,3,6,3"/>
                  <Label Content="times" Margin="0,2,18,2"/>
                  <CheckBox Name="ShowProgress" Content="Progress dialog"/>
                  <CheckBox Name="ShowCompletion" Content="Completion prompt"/>
                </WrapPanel>
                <Label Grid.Row="12" Content="Pre-install PowerShell"/>
                <TextBox Grid.Row="12" Grid.Column="1" Name="InstallPre" Style="{StaticResource Code}" Height="90"/>
                <Label Grid.Row="13" Content="Custom install PowerShell"/>
                <TextBox Grid.Row="13" Grid.Column="1" Name="InstallCustom" Style="{StaticResource Code}" Height="120"/>
                <Label Grid.Row="14" Content="Post-install PowerShell"/>
                <TextBox Grid.Row="14" Grid.Column="1" Name="InstallPost" Style="{StaticResource Code}" Height="90"/>
              </Grid>
            </Border>
          </ScrollViewer>
        </TabItem>

        <TabItem Header="Uninstall">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <Border Style="{StaticResource Card}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="180"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Style="{StaticResource Hint}"
                           Text="Defines the Uninstall phase. 'Installed app by name' searches the Uninstall registry (both views) and runs the registered uninstaller, which is the most robust option for EXE installers."/>
                <Label Grid.Row="1" Content="Uninstall method"/>
                <ComboBox Grid.Row="1" Grid.Column="1" Name="UninstallType" Width="380" HorizontalAlignment="Left"/>
                <Label Grid.Row="2" Content="MSI product code"/>
                <TextBox Grid.Row="2" Grid.Column="1" Name="UninstallProductCode" FontFamily="Cascadia Mono, Consolas" FontSize="12" Width="380" HorizontalAlignment="Left"/>
                <Label Grid.Row="3" Content="Installed app name"/>
                <DockPanel Grid.Row="3" Grid.Column="1">
                  <ComboBox DockPanel.Dock="Right" Name="UninstallAppType" Width="90" Margin="6,3,0,3"/>
                  <Label DockPanel.Dock="Right" Content="App type" Margin="14,2,0,2"/>
                  <CheckBox DockPanel.Dock="Right" Name="UninstallNameRegex" Content="Regex" Margin="14,7,0,4"/>
                  <TextBox Name="UninstallName"/>
                </DockPanel>
                <TextBlock Grid.Row="4" Grid.Column="1" Style="{StaticResource Hint}" Text="DisplayName as shown in Apps and Features. Wildcards (*) are allowed; tick Regex for a .NET regular expression."/>
                <Label Grid.Row="5" Content="Uninstaller / script"/>
                <TextBox Grid.Row="5" Grid.Column="1" Name="UninstallFile" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
                <TextBlock Grid.Row="6" Grid.Column="1" Style="{StaticResource Hint}" Text="EXE method: full path on the device, $env:ProgramFiles etc. allowed. Script method: .ps1, .cmd, .bat or .vbs file name inside Files\."/>
                <Label Grid.Row="7" Content="Arguments"/>
                <DockPanel Grid.Row="7" Grid.Column="1">
                  <TextBox DockPanel.Dock="Right" Name="UninstallSuccessCodes" Width="120" Margin="8,3,0,3" FontFamily="Cascadia Mono, Consolas" FontSize="12"
                           ToolTip="Extra exit codes that mean the uninstall worked (Chromium-based browsers return 19). They are ignored, so the package still exits 0 for Intune."/>
                  <Label DockPanel.Dock="Right" Content="Success exit codes" Margin="14,2,0,2"/>
                  <TextBox Name="UninstallArgs" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
                </DockPanel>
                <Label Grid.Row="8" Content="MSIX package name"/>
                <TextBox Grid.Row="8" Grid.Column="1" Name="UninstallPackageName" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
                <Label Grid.Row="9" Content="Pre-uninstall PowerShell"/>
                <TextBox Grid.Row="9" Grid.Column="1" Name="UninstallPre" Style="{StaticResource Code}" Height="90"/>
                <Label Grid.Row="10" Content="Custom uninstall PowerShell"/>
                <TextBox Grid.Row="10" Grid.Column="1" Name="UninstallCustom" Style="{StaticResource Code}" Height="120"/>
                <Label Grid.Row="11" Content="Post-uninstall PowerShell"/>
                <TextBox Grid.Row="11" Grid.Column="1" Name="UninstallPost" Style="{StaticResource Code}" Height="90"/>
              </Grid>
            </Border>
          </ScrollViewer>
        </TabItem>

        <TabItem Header="Detection">
          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="180"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Style="{StaticResource Hint}"
                         Text="Generates the Intune custom detection script (exit 0 + STDOUT = installed). Registry methods check the 64-bit and 32-bit HKLM views and HKCU. Minimum version makes the rule 'this version or newer', which keeps upgrades detected correctly."/>
              <Label Grid.Row="1" Content="Detection method"/>
              <ComboBox Grid.Row="1" Grid.Column="1" Name="DetectType" Width="380" HorizontalAlignment="Left"/>
              <Label Grid.Row="2" Content="MSI product code"/>
              <TextBox Grid.Row="2" Grid.Column="1" Name="DetectProductCode" FontFamily="Cascadia Mono, Consolas" FontSize="12" Width="380" HorizontalAlignment="Left"/>
              <Label Grid.Row="3" Content="Minimum version"/>
              <TextBox Grid.Row="3" Grid.Column="1" Name="DetectMinVersion" FontFamily="Cascadia Mono, Consolas" FontSize="12" Width="220" HorizontalAlignment="Left"/>
              <Label Grid.Row="4" Content="Display name"/>
              <DockPanel Grid.Row="4" Grid.Column="1">
                <ComboBox DockPanel.Dock="Right" Name="DetectMatchMode" Width="120" Margin="6,3,0,3"/>
                <TextBox Name="DetectDisplayName"/>
              </DockPanel>
              <Label Grid.Row="5" Content="File path"/>
              <DockPanel Grid.Row="5" Grid.Column="1">
                <CheckBox DockPanel.Dock="Right" Name="DetectCheckVersion" Content="Compare file version" Margin="14,7,0,4"/>
                <TextBox Name="DetectFilePath" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
              </DockPanel>
              <Label Grid.Row="6" Content="MSIX package name"/>
              <TextBox Grid.Row="6" Grid.Column="1" Name="DetectPackageName" FontFamily="Cascadia Mono, Consolas" FontSize="12"/>
              <Label Grid.Row="7" Content="Custom script"/>
              <TextBox Grid.Row="7" Grid.Column="1" Name="DetectScript" Style="{StaticResource Code}" Height="120"/>
              <StackPanel Grid.Row="8" Grid.Column="1" Orientation="Horizontal" Margin="0,8,0,4">
                <Button Name="BtnDetectPreview" Content="Preview detection script" Margin="0,3,0,3"/>
                <Button Name="BtnDetectTest" Content="Run preview on this PC"/>
                <TextBlock Name="DetectTestResult" VerticalAlignment="Center" Margin="14,0,0,0" FontWeight="SemiBold"/>
              </StackPanel>
              <TextBox Grid.Row="9" Grid.Column="1" Name="DetectPreview" Style="{StaticResource Code}" IsReadOnly="True" Background="#FAFAFA"/>
            </Grid>
          </Border>
        </TabItem>

        <TabItem Header="Build">
          <Border Style="{StaticResource Card}">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="180"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Style="{StaticResource Hint}"
                         Text="Output: Destination\Vendor_Name_Version\ with Package\ (the PSADT folder to wrap), Detect-Name.ps1, Package.json, README.md with the Intune settings, and optionally Intune\Vendor_Name_Version.intunewin."/>
              <Label Grid.Row="1" Content="Destination folder"/>
              <DockPanel Grid.Row="1" Grid.Column="1">
                <Button DockPanel.Dock="Right" Name="BtnBrowseDest" Content="Browse..."/>
                <TextBox Name="OutDestination"/>
              </DockPanel>
              <Label Grid.Row="2" Content="Intune deploy mode"/>
              <DockPanel Grid.Row="2" Grid.Column="1">
                <ComboBox DockPanel.Dock="Left" Name="OutDeployMode" Width="170" VerticalAlignment="Top"/>
                <TextBlock Style="{StaticResource Hint}" Margin="14,8,0,0" Text="Used in the README install/uninstall command lines. Silent = no dialogs (Required apps); Auto = dialogs when a user is logged on."/>
              </DockPanel>
              <Label Grid.Row="3" Content="Options"/>
              <WrapPanel Grid.Row="3" Grid.Column="1">
                <CheckBox Name="OutOverwrite" Content="Overwrite existing Package folder"/>
                <CheckBox Name="OutBuildIntuneWin" Content="Build .intunewin"/>
              </WrapPanel>
              <Label Grid.Row="4" Content="IntuneWinAppUtil.exe"/>
              <DockPanel Grid.Row="4" Grid.Column="1">
                <Button DockPanel.Dock="Right" Name="BtnDownloadTool" Content="Download"/>
                <Button DockPanel.Dock="Right" Name="BtnBrowseTool" Content="Browse..."/>
                <TextBox Name="OutIntuneWinTool"/>
              </DockPanel>
              <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal" Margin="0,12,0,4">
                <Button Name="BtnGenerate" Style="{StaticResource Primary}" Content="Generate package" Margin="0,3,0,3"/>
                <Button Name="BtnPreviewScript" Content="Preview deployment script"/>
                <Button Name="BtnOpenOutput" Content="Open output folder"/>
              </StackPanel>
              <TextBlock Grid.Row="6" Grid.Column="1" Style="{StaticResource Hint}" Margin="0,4,0,10" Text="Generate copies sources, creates the PSADT template (downloads the toolkit once if needed), writes the scripts, syntax-checks them and saves Package.json next to the package."/>
              <TextBox Grid.Row="7" Grid.Column="1" Name="OutPreview" Style="{StaticResource Code}" IsReadOnly="True" Background="#FAFAFA"/>
            </Grid>
          </Border>
        </TabItem>

        <TabItem Header="Intune" Name="TabIntune">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <Border Style="{StaticResource Card}">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="180"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Style="{StaticResource Hint}"
                           Text="Everything below is filled in from the other tabs; anything you type here overrides it. Publish creates the Win32 app, uploads the .intunewin and sets the commands, detection rule, return codes and requirements. Assignments are left for you."/>

                <Label Grid.Row="1" Content="Tenant"/>
                <DockPanel Grid.Row="1" Grid.Column="1">
                  <Button DockPanel.Dock="Right" Name="BtnGraphConnect" Content="Connect..."/>
                  <TextBox Name="IntTenantId" Width="260" HorizontalAlignment="Left"/>
                  <TextBlock Name="IntConnStatus" Style="{StaticResource Hint}" Margin="14,8,0,0" Text="Not connected. Blank tenant = whichever tenant you sign in to."/>
                </DockPanel>

                <Label Grid.Row="2" Content="App registration"/>
                <DockPanel Grid.Row="2" Grid.Column="1">
                  <TextBox Name="IntClientId" Width="330" HorizontalAlignment="Left"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="14,8,0,0" Text="Blank = Microsoft Graph PowerShell client. Needs DeviceManagementApps.ReadWrite.All."/>
                </DockPanel>

                <Label Grid.Row="3" Content="Name"/>
                <TextBox Grid.Row="3" Grid.Column="1" Name="IntDisplayName"/>

                <Label Grid.Row="4" Content="Publisher"/>
                <TextBox Grid.Row="4" Grid.Column="1" Name="IntPublisher"/>

                <Label Grid.Row="5" Content="Description"/>
                <TextBox Grid.Row="5" Grid.Column="1" Name="IntDescription" Height="58" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" VerticalContentAlignment="Top"/>

                <Label Grid.Row="6" Content="Developer / Owner"/>
                <DockPanel Grid.Row="6" Grid.Column="1">
                  <TextBox Name="IntDeveloper" Width="300" HorizontalAlignment="Left"/>
                  <TextBox Name="IntOwner" Width="240" Margin="8,3,0,3" HorizontalAlignment="Left"/>
                </DockPanel>

                <Label Grid.Row="7" Content="Information / Privacy URL"/>
                <DockPanel Grid.Row="7" Grid.Column="1">
                  <TextBox Name="IntInfoUrl" Width="300" HorizontalAlignment="Left"/>
                  <TextBox Name="IntPrivacyUrl" Width="300" Margin="8,3,0,3" HorizontalAlignment="Left"/>
                </DockPanel>

                <Label Grid.Row="8" Content="Install command"/>
                <TextBox Grid.Row="8" Grid.Column="1" Name="IntInstallCmd" Style="{StaticResource Code}"/>

                <Label Grid.Row="9" Content="Uninstall command"/>
                <TextBox Grid.Row="9" Grid.Column="1" Name="IntUninstallCmd" Style="{StaticResource Code}"/>

                <Label Grid.Row="10" Content="Install behavior"/>
                <DockPanel Grid.Row="10" Grid.Column="1">
                  <ComboBox DockPanel.Dock="Left" Name="IntRunAs" Width="210"/>
                  <ComboBox DockPanel.Dock="Left" Name="IntRestart" Width="300" Margin="8,3,0,3"/>
                  <TextBox Name="IntMaxRunTime" Width="60" Margin="8,3,0,3" HorizontalAlignment="Left"/>
                  <TextBlock Style="{StaticResource Hint}" Margin="8,8,0,0" Text="max run time (minutes)"/>
                </DockPanel>

                <Label Grid.Row="11" Content="Requirements"/>
                <DockPanel Grid.Row="11" Grid.Column="1">
                  <ComboBox DockPanel.Dock="Left" Name="IntMinOs" Width="230"/>
                  <ComboBox DockPanel.Dock="Left" Name="IntArch" Width="130" Margin="8,3,0,3" IsEditable="True"/>
                  <CheckBox Name="IntAllowUninstall" Content="Allow uninstall for Available assignments" Margin="14,7,0,4"/>
                </DockPanel>

                <Label Grid.Row="12" Content="Detection"/>
                <TextBlock Grid.Row="12" Grid.Column="1" Style="{StaticResource Hint}" Margin="0,8,0,0"
                           Text="The script from the Detection tab is uploaded as the detection rule (64-bit, no signature check). Return codes come from the Install tab."/>

                <StackPanel Grid.Row="13" Grid.Column="1" Orientation="Horizontal" Margin="0,12,0,6">
                  <Button Name="BtnIntunePublish" Style="{StaticResource Primary}" Content="Publish to Intune" Margin="0,3,0,3"/>
                  <Button Name="BtnIntunePreview" Content="Preview app JSON"/>
                  <Button Name="BtnIntuneReset" Content="Reset to auto values"/>
                </StackPanel>

                <TextBox Grid.Row="14" Grid.Column="1" Name="IntPreview" Style="{StaticResource Code}" IsReadOnly="True" Background="#FAFAFA" MinHeight="120"/>
              </Grid>
            </Border>
          </ScrollViewer>
        </TabItem>

      </TabControl>
      <GridSplitter Grid.Row="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" ResizeDirection="Rows" Cursor="SizeNS"/>
      <TextBox Grid.Row="2" Name="LogBox" Style="{StaticResource Code}" IsReadOnly="True" Background="#1C1C1F" Foreground="#D6D6D6" BorderBrush="#1C1C1F" Margin="0"/>
    </Grid>
  </DockPanel>
</Window>
'@

$script:Window = [System.Windows.Markup.XamlReader]::Parse($xaml)
# The installer ships PsadtPackager.ico next to the script; use it for the window and taskbar when it is there.
$windowIcon = Join-Path $PSScriptRoot 'PsadtPackager.ico'
if (Test-Path -LiteralPath $windowIcon) { try { $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$windowIcon) } catch { } }
if (-not $script:Window.Icon)
{
    # Run straight from the script (no .ico next to it): draw the same mark the installer's icon uses.
    try
    {
        $iconSize = 64
        $visual = New-Object System.Windows.Media.DrawingVisual
        $dc = $visual.RenderOpen()
        $dc.DrawImage($script:Window.FindResource('AppIcon'), (New-Object System.Windows.Rect(0, 0, $iconSize, $iconSize)))
        $dc.Close()
        $bitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($iconSize, $iconSize, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($visual)
        $script:Window.Icon = $bitmap
    }
    catch { }
}
$script:ui = @{}
foreach ($m in [regex]::Matches($xaml, 'Name="(\w+)"')) { $script:ui[$m.Groups[1].Value] = $script:Window.FindName($m.Groups[1].Value) }
$script:CurrentDefinitionPath = $null
$script:LastOutputPath = $null

function Invoke-UiRefresh
{
    $script:Window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
}

$script:LogSink = {
    param($Line, $Level)
    $box = $script:ui.LogBox
    $box.AppendText($Line + "`r`n")
    $box.ScrollToEnd()
    # During an auto-package run the status bar shows the stage, not every log line.
    if (-not $script:AutoPackageRunning) { $script:ui.StatusText.Text = $Line.Substring(11) }
    Invoke-UiRefresh
}

# Auto-package progress: an elapsed-time ticker (it ticks while long steps keep the window pumping) and the taskbar
# button's progress, so a run is visibly alive even with the window minimised.
$script:AutoPackageRunning = $false
$script:AutoPackageStarted = $null
$script:AutoPackageStep    = ''
$script:ElapsedTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ElapsedTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:ElapsedTimer.Add_Tick({
    if (-not $script:AutoPackageStarted) { return }
    $e = (Get-Date) - $script:AutoPackageStarted
    $script:ui.DropElapsed.Text = ('{0}:{1:00} elapsed{2}' -f [int][Math]::Floor($e.TotalMinutes), $e.Seconds, $(if ($script:AutoPackageStep) { "  -  $($script:AutoPackageStep)" } else { '' }))
})
$script:Window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo

# An unexpected error in an event handler is logged instead of closing the window (and losing the work on it).
$script:Window.Dispatcher.Add_UnhandledException({
    param($dispatcherSource, $e)
    try { Write-PackagerLog "Unexpected error: $($e.Exception.Message)" -Level Error } catch { }
    $e.Handled = $true
})
$script:Window.Add_Activated({
    # The finished state stays on the taskbar button until the window is looked at.
    if (-not $script:AutoPackageRunning) { $script:Window.TaskbarItemInfo.ProgressState = 'None' }
})

function Show-Message
{
    param([string]$Text, [string]$Title = 'PSADT Packager', [string]$Icon = 'Information')
    [System.Windows.MessageBox]::Show($script:Window, $Text, $Title, 'OK', $Icon) | Out-Null
}

function Confirm-Action
{
    param([string]$Text, [string]$Title = 'PSADT Packager')
    return ([System.Windows.MessageBox]::Show($script:Window, $Text, $Title, 'YesNo', 'Question') -eq 'Yes')
}

function Select-FileDialog
{
    param([string]$Title, [string]$Filter = 'All files (*.*)|*.*', [switch]$Multi, [string]$InitialDirectory)
    $d = New-Object Microsoft.Win32.OpenFileDialog
    $d.Title = $Title
    $d.Filter = $Filter
    $d.Multiselect = [bool]$Multi
    if ($InitialDirectory -and (Test-Path -LiteralPath $InitialDirectory)) { $d.InitialDirectory = $InitialDirectory }
    # The leading comma is required: PowerShell unrolls a returned collection, so a single
    # selected file would come back as a bare string and $result[0] would be its first
    # character ('C' from 'C:\...'). Do not remove it.
    if ($d.ShowDialog($script:Window) -eq $true) { return ,@($d.FileNames) }
    return ,@()
}

function Select-SaveDialog
{
    param([string]$Title, [string]$Filter, [string]$FileName)
    $d = New-Object Microsoft.Win32.SaveFileDialog
    $d.Title = $Title
    $d.Filter = $Filter
    if ($FileName) { $d.FileName = $FileName }
    if ($d.ShowDialog($script:Window) -eq $true) { return $d.FileName }
    return $null
}

function Select-FolderDialog
{
    param([string]$Description)
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $Description
    $d.ShowNewFolderButton = $true
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    return $null
}

function Get-ComboCode
{
    param($Combo, [string[]]$Codes, [string]$Default)
    $idx = $Combo.SelectedIndex
    if ($idx -ge 0 -and $idx -lt $Codes.Count) { return $Codes[$idx] }
    return $Default
}

function Set-ComboCode
{
    param($Combo, [string[]]$Codes, [string]$Value, [int]$DefaultIndex = 0)
    $idx = [Array]::IndexOf($Codes, "$Value")
    if ($idx -lt 0) { $idx = $DefaultIndex }
    $Combo.SelectedIndex = $idx
}

function Update-InstallFileChoices
{
    $current = $script:ui.InstallFile.Text
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($src in @($script:ui.FilesList.Items))
    {
        $s = "$src"
        if ($s.EndsWith('\*'))
        {
            $dir = $s.Substring(0, $s.Length - 2)
            if (Test-Path -LiteralPath $dir -PathType Container)
            {
                Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object { $names.Add($_.Name) }
            }
        }
        elseif (Test-Path -LiteralPath $s -PathType Container)
        {
            $leaf = Split-Path -Path $s -Leaf
            Get-ChildItem -LiteralPath $s -File -ErrorAction SilentlyContinue | ForEach-Object { $names.Add("$leaf\$($_.Name)") }
        }
        else
        {
            $names.Add((Split-Path -Path $s -Leaf))
        }
    }
    $script:ui.InstallFile.ItemsSource = @($names | Sort-Object -Unique)
    $script:ui.InstallFile.Text = $current
}

function Get-UiDefinition
{
    $u = $script:ui
    $d = New-PackageDefinition
    $d.App.Vendor        = $u.AppVendor.Text.Trim()
    $d.App.Name          = $u.AppName.Text.Trim()
    $d.App.Version       = $u.AppVersion.Text.Trim()
    $d.App.Arch          = "$($u.AppArch.Text)".Trim()
    $d.App.Lang          = $u.AppLang.Text.Trim()
    $d.App.Revision      = $u.AppRevision.Text.Trim()
    $d.App.ScriptVersion = $u.AppScriptVersion.Text.Trim()
    $d.App.Author        = $u.AppAuthor.Text.Trim()

    $d.Sources.Files        = @($u.FilesList.Items | ForEach-Object { "$_" })
    $d.Sources.SupportFiles = @($u.SupportList.Items | ForEach-Object { "$_" })

    $d.Install.Type                 = Get-ComboCode $u.InstallType $script:InstallTypeCodes 'MSI'
    $d.Install.File                 = "$($u.InstallFile.Text)".Trim()
    $d.Install.Arguments            = $u.InstallArgs.Text.Trim()
    $d.Install.Transforms           = @(Split-ListText $u.InstallTransforms.Text)
    $d.Install.ProductCode          = $u.InstallProductCode.Text.Trim()
    $d.Install.ProcessesToClose     = @(Split-ListText $u.CloseProcesses.Text)
    $d.Install.SuccessExitCodes     = @(Split-ListText $u.SuccessCodes.Text | Where-Object { $_ -match '^-?\d+$' } | ForEach-Object { [int]$_ })
    $d.Install.RebootExitCodes      = @(Split-ListText $u.RebootCodes.Text  | Where-Object { $_ -match '^-?\d+$' } | ForEach-Object { [int]$_ })
    $d.Install.ShowWelcome          = [bool]$u.ShowWelcome.IsChecked
    $d.Install.AllowDefer           = [bool]$u.AllowDefer.IsChecked
    $d.Install.DeferTimes           = if ($u.DeferTimes.Text -match '^\d+$') { [int]$u.DeferTimes.Text } else { 3 }
    $d.Install.ShowProgress         = [bool]$u.ShowProgress.IsChecked
    $d.Install.ShowCompletionPrompt = [bool]$u.ShowCompletion.IsChecked
    $d.Install.PreScript            = $u.InstallPre.Text
    $d.Install.CustomScript         = $u.InstallCustom.Text
    $d.Install.PostScript           = $u.InstallPost.Text

    $d.Uninstall.Type            = Get-ComboCode $u.UninstallType $script:UninstallTypeCodes 'MSI'
    $d.Uninstall.ProductCode     = $u.UninstallProductCode.Text.Trim()
    $d.Uninstall.Name            = $u.UninstallName.Text.Trim()
    $d.Uninstall.NameIsRegex     = [bool]$u.UninstallNameRegex.IsChecked
    $d.Uninstall.ApplicationType = Get-ComboCode $u.UninstallAppType $script:AppTypeCodes 'All'
    $d.Uninstall.File            = $u.UninstallFile.Text.Trim()
    $d.Uninstall.Arguments       = $u.UninstallArgs.Text.Trim()
    $d.Uninstall.SuccessExitCodes = @(Split-ListText $u.UninstallSuccessCodes.Text | Where-Object { $_ -match '^-?\d+$' } | ForEach-Object { [int]$_ })
    $d.Uninstall.PackageName     = $u.UninstallPackageName.Text.Trim()
    $d.Uninstall.PreScript       = $u.UninstallPre.Text
    $d.Uninstall.CustomScript    = $u.UninstallCustom.Text
    $d.Uninstall.PostScript      = $u.UninstallPost.Text

    $d.Detection.Type             = Get-ComboCode $u.DetectType $script:DetectTypeCodes 'MSI'
    $d.Detection.ProductCode      = $u.DetectProductCode.Text.Trim()
    $d.Detection.MinVersion       = $u.DetectMinVersion.Text.Trim()
    $d.Detection.DisplayName      = $u.DetectDisplayName.Text.Trim()
    $d.Detection.MatchMode        = Get-ComboCode $u.DetectMatchMode $script:MatchModeCodes 'Wildcard'
    $d.Detection.FilePath         = $u.DetectFilePath.Text.Trim()
    $d.Detection.CheckFileVersion = [bool]$u.DetectCheckVersion.IsChecked
    $d.Detection.PackageName      = $u.DetectPackageName.Text.Trim()
    $d.Detection.Script           = $u.DetectScript.Text

    $d.Intune.TenantId                = $u.IntTenantId.Text.Trim()
    $d.Intune.ClientId                = $u.IntClientId.Text.Trim()
    $d.Intune.DisplayName             = $u.IntDisplayName.Text.Trim()
    $d.Intune.Publisher               = $u.IntPublisher.Text.Trim()
    $d.Intune.Description             = $u.IntDescription.Text.Trim()
    $d.Intune.Developer               = $u.IntDeveloper.Text.Trim()
    $d.Intune.Owner                   = $u.IntOwner.Text.Trim()
    $d.Intune.InformationUrl          = $u.IntInfoUrl.Text.Trim()
    $d.Intune.PrivacyUrl              = $u.IntPrivacyUrl.Text.Trim()
    $d.Intune.InstallCommand          = $u.IntInstallCmd.Text.Trim()
    $d.Intune.UninstallCommand        = $u.IntUninstallCmd.Text.Trim()
    $d.Intune.RunAsAccount            = Get-ComboCode $u.IntRunAs $script:RunAsChoices 'system'
    $d.Intune.RestartBehavior         = Get-ComboCode $u.IntRestart $script:RestartChoices 'basedOnReturnCode'
    $d.Intune.MaxRunTimeInMinutes     = if ($u.IntMaxRunTime.Text -match '^\d+$') { [int]$u.IntMaxRunTime.Text } else { 60 }
    $d.Intune.MinimumOs               = Get-ComboCode $u.IntMinOs $script:MinOsCodes 'v10_1809'
    $d.Intune.Architecture            = "$($u.IntArch.Text)".Trim()
    $d.Intune.AllowAvailableUninstall = [bool]$u.IntAllowUninstall.IsChecked

    $d.Output.Destination      = $u.OutDestination.Text.Trim()
    $d.Output.DeployMode       = Get-ComboCode $u.OutDeployMode $script:DeployModeChoices 'Silent'
    $d.Output.BuildIntuneWin   = [bool]$u.OutBuildIntuneWin.IsChecked
    $d.Output.IntuneWinAppUtil = $u.OutIntuneWinTool.Text.Trim()
    return $d
}

function Set-UiDefinition
{
    param([Parameter(Mandatory)]$d)
    $u = $script:ui
    $u.AppVendor.Text        = "$($d.App.Vendor)"
    $u.AppName.Text          = "$($d.App.Name)"
    $u.AppVersion.Text       = "$($d.App.Version)"
    $u.AppArch.Text          = "$($d.App.Arch)"
    $u.AppLang.Text          = "$($d.App.Lang)"
    $u.AppRevision.Text      = "$($d.App.Revision)"
    $u.AppScriptVersion.Text = "$($d.App.ScriptVersion)"
    $u.AppAuthor.Text        = "$($d.App.Author)"

    $u.FilesList.Items.Clear();   foreach ($f in @($d.Sources.Files        | Where-Object { "$_" })) { [void]$u.FilesList.Items.Add("$f") }
    $u.SupportList.Items.Clear(); foreach ($f in @($d.Sources.SupportFiles | Where-Object { "$_" })) { [void]$u.SupportList.Items.Add("$f") }
    Update-InstallFileChoices

    Set-ComboCode $u.InstallType $script:InstallTypeCodes $d.Install.Type
    $u.InstallFile.Text        = "$($d.Install.File)"
    $u.InstallArgs.Text        = "$($d.Install.Arguments)"
    $u.InstallTransforms.Text  = (@($d.Install.Transforms) -join '; ')
    $u.InstallProductCode.Text = "$($d.Install.ProductCode)"
    $u.CloseProcesses.Text     = (@($d.Install.ProcessesToClose) -join ', ')
    $u.SuccessCodes.Text       = (@($d.Install.SuccessExitCodes) -join ', ')
    $u.RebootCodes.Text        = (@($d.Install.RebootExitCodes) -join ', ')
    $u.ShowWelcome.IsChecked   = [bool]$d.Install.ShowWelcome
    $u.AllowDefer.IsChecked    = [bool]$d.Install.AllowDefer
    $u.DeferTimes.Text         = "$($d.Install.DeferTimes)"
    $u.ShowProgress.IsChecked  = [bool]$d.Install.ShowProgress
    $u.ShowCompletion.IsChecked= [bool]$d.Install.ShowCompletionPrompt
    $u.InstallPre.Text         = "$($d.Install.PreScript)"
    $u.InstallCustom.Text      = "$($d.Install.CustomScript)"
    $u.InstallPost.Text        = "$($d.Install.PostScript)"

    Set-ComboCode $u.UninstallType $script:UninstallTypeCodes $d.Uninstall.Type
    $u.UninstallProductCode.Text  = "$($d.Uninstall.ProductCode)"
    $u.UninstallName.Text         = "$($d.Uninstall.Name)"
    $u.UninstallNameRegex.IsChecked = [bool]$d.Uninstall.NameIsRegex
    Set-ComboCode $u.UninstallAppType $script:AppTypeCodes $d.Uninstall.ApplicationType
    $u.UninstallFile.Text         = "$($d.Uninstall.File)"
    $u.UninstallArgs.Text         = "$($d.Uninstall.Arguments)"
    $u.UninstallSuccessCodes.Text = (@($d.Uninstall.SuccessExitCodes) -join ', ')
    $u.UninstallPackageName.Text  = "$($d.Uninstall.PackageName)"
    $u.UninstallPre.Text          = "$($d.Uninstall.PreScript)"
    $u.UninstallCustom.Text       = "$($d.Uninstall.CustomScript)"
    $u.UninstallPost.Text         = "$($d.Uninstall.PostScript)"

    Set-ComboCode $u.DetectType $script:DetectTypeCodes $d.Detection.Type
    $u.DetectProductCode.Text       = "$($d.Detection.ProductCode)"
    $u.DetectMinVersion.Text        = "$($d.Detection.MinVersion)"
    $u.DetectDisplayName.Text       = "$($d.Detection.DisplayName)"
    Set-ComboCode $u.DetectMatchMode $script:MatchModeCodes $d.Detection.MatchMode 1
    $u.DetectFilePath.Text          = "$($d.Detection.FilePath)"
    $u.DetectCheckVersion.IsChecked = [bool]$d.Detection.CheckFileVersion
    $u.DetectPackageName.Text       = "$($d.Detection.PackageName)"
    $u.DetectScript.Text            = "$($d.Detection.Script)"

    $script:IntuneAutoFilled = @{}
    $u.IntTenantId.Text       = "$($d.Intune.TenantId)"
    $u.IntClientId.Text       = "$($d.Intune.ClientId)"
    $u.IntDisplayName.Text    = "$($d.Intune.DisplayName)"
    $u.IntPublisher.Text      = "$($d.Intune.Publisher)"
    $u.IntDescription.Text    = "$($d.Intune.Description)"
    $u.IntDeveloper.Text      = "$($d.Intune.Developer)"
    $u.IntOwner.Text          = "$($d.Intune.Owner)"
    $u.IntInfoUrl.Text        = "$($d.Intune.InformationUrl)"
    $u.IntPrivacyUrl.Text     = "$($d.Intune.PrivacyUrl)"
    $u.IntInstallCmd.Text     = "$($d.Intune.InstallCommand)"
    $u.IntUninstallCmd.Text   = "$($d.Intune.UninstallCommand)"
    Set-ComboCode $u.IntRunAs $script:RunAsChoices $d.Intune.RunAsAccount
    Set-ComboCode $u.IntRestart $script:RestartChoices $d.Intune.RestartBehavior
    $u.IntMaxRunTime.Text     = "$($d.Intune.MaxRunTimeInMinutes)"
    Set-ComboCode $u.IntMinOs $script:MinOsCodes $d.Intune.MinimumOs 4
    $u.IntArch.Text           = "$($d.Intune.Architecture)"
    $u.IntAllowUninstall.IsChecked = [bool]$d.Intune.AllowAvailableUninstall

    if ("$($d.Output.Destination)") { $u.OutDestination.Text = "$($d.Output.Destination)" }
    Set-ComboCode $u.OutDeployMode $script:DeployModeChoices $d.Output.DeployMode
    $u.OutBuildIntuneWin.IsChecked = [bool]$d.Output.BuildIntuneWin
    if ("$($d.Output.IntuneWinAppUtil)") { $u.OutIntuneWinTool.Text = "$($d.Output.IntuneWinAppUtil)" }
    Update-FieldStates
}

function Update-FieldStates
{
    # Enables only the fields that apply to the selected install / uninstall / detection methods.
    $u = $script:ui
    $it = Get-ComboCode $u.InstallType $script:InstallTypeCodes 'MSI'
    $u.InstallFile.IsEnabled        = $it -ne 'Custom'
    $u.BtnInstallAutoFill.IsEnabled = $it -ne 'Custom'
    $u.InstallArgs.IsEnabled        = $it -ne 'Custom'
    $u.InstallPreset.IsEnabled      = $it -eq 'EXE'
    $u.BtnProbeSandbox.IsEnabled    = $it -in @('EXE', 'Script') -and -not $script:AutoPackageRunning
    $u.InstallTransforms.IsEnabled  = $it -eq 'MSI'
    $u.InstallProductCode.IsEnabled = $it -eq 'MSI'
    $u.InstallCustom.IsEnabled      = $it -eq 'Custom'
    $u.DeferTimes.IsEnabled         = [bool]$u.ShowWelcome.IsChecked -and [bool]$u.AllowDefer.IsChecked
    $u.AllowDefer.IsEnabled         = [bool]$u.ShowWelcome.IsChecked

    $ut = Get-ComboCode $u.UninstallType $script:UninstallTypeCodes 'MSI'
    $u.UninstallProductCode.IsEnabled = $ut -eq 'MSI'
    $u.UninstallName.IsEnabled        = $ut -eq 'Name'
    $u.UninstallNameRegex.IsEnabled   = $ut -eq 'Name'
    $u.UninstallAppType.IsEnabled     = $ut -eq 'Name'
    $u.UninstallFile.IsEnabled        = $ut -in @('EXE', 'Script')
    $u.UninstallArgs.IsEnabled        = $ut -in @('MSI', 'Name', 'EXE', 'Script')
    $u.UninstallPackageName.IsEnabled = $ut -eq 'MSIX'
    $u.UninstallCustom.IsEnabled      = $ut -eq 'Custom'
    $u.UninstallPre.IsEnabled         = $ut -ne 'None'
    $u.UninstallPost.IsEnabled        = $ut -ne 'None'

    $dt = Get-ComboCode $u.DetectType $script:DetectTypeCodes 'MSI'
    $u.DetectProductCode.IsEnabled  = $dt -eq 'MSI'
    $u.DetectMinVersion.IsEnabled   = $dt -ne 'Script'
    $u.DetectDisplayName.IsEnabled  = $dt -eq 'Registry'
    $u.DetectMatchMode.IsEnabled    = $dt -eq 'Registry'
    $u.DetectFilePath.IsEnabled     = $dt -eq 'File'
    $u.DetectCheckVersion.IsEnabled = $dt -eq 'File'
    $u.DetectPackageName.IsEnabled  = $dt -eq 'MSIX'
    $u.DetectScript.IsEnabled       = $dt -eq 'Script'

    $u.OutIntuneWinTool.IsEnabled = [bool]$u.OutBuildIntuneWin.IsChecked
    $u.BtnBrowseTool.IsEnabled    = [bool]$u.OutBuildIntuneWin.IsChecked
    $u.BtnDownloadTool.IsEnabled  = [bool]$u.OutBuildIntuneWin.IsChecked
}

function Import-InstallerIntoUi
{
    param([string]$Path)
    try
    {
        Write-PackagerLog "Reading $Path"
        $info = Get-InstallerInfo -Path $Path
        $def  = Get-UiDefinition
        [void](Set-DefinitionFromInstaller -Def $def -Info $info)
        Set-UiDefinition -d $def
        if ($info.Type -eq 'EXE')
        {
            $keys = @($script:SilentPresets.Keys)
            $script:ui.InstallPreset.SelectedIndex = [Math]::Max(0, [Array]::IndexOf($keys, $info.Engine))
            $script:ui.InstallArgs.Text = $info.InstallArgs
        }
        $summary = "Type: $($info.Type)  Engine: $($info.Engine)  Vendor: $($info.Vendor)  Name: $($info.Name)  Version: $($info.Version)"
        if ($info.ProductCode) { $summary += "  ProductCode: $($info.ProductCode)" }
        if ($info.PackageName) { $summary += "  Package: $($info.PackageName)" }
        Write-PackagerLog $summary
        if ($info.Type -eq 'EXE')
        {
            $hits = @(Find-InstallerSwitchStrings -Path $Path)
            if ($hits.Count -gt 0) { Write-PackagerLog "Switch strings present in the binary: $($hits -join ', ')" }
            if ($info.Engine -eq 'Unknown')
            {
                Write-PackagerLog "Installer engine not recognised. Use 'Find switches in Sandbox' on the Install tab to test candidates safely." -Level Warn
            }
        }
    }
    catch
    {
        Write-PackagerLog "Could not read installer: $($_.Exception.Message)" -Level Error
        Show-Message -Text $_.Exception.Message -Title 'Read installer' -Icon Error
    }
}

function Set-DropZone
{
    # The drop card on the Application tab doubles as the progress and result panel of an auto-package run.
    param([string]$Title, [string]$Detail, [ValidateSet('Idle', 'Busy', 'Validated', 'Built', 'NeedsAttention', 'Failed')][string]$State = 'Idle')
    $u = $script:ui
    if ($PSBoundParameters.ContainsKey('Title'))  { $u.DropTitle.Text = $Title }
    if ($PSBoundParameters.ContainsKey('Detail')) { $u.DropDetail.Text = $Detail }
    $colour = switch ($State) { 'Validated' { '#0E7A0D' } 'NeedsAttention' { '#9A5B00' } 'Failed' { '#C42B1C' } default { '#1B1B1B' } }
    $u.DropTitle.Foreground = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($colour)
    $busy = $State -eq 'Busy'
    foreach ($e in @($u.DropProgress, $u.StatusProgress, $u.DropElapsed)) { $e.Visibility = $(if ($busy) { 'Visible' } else { 'Collapsed' }) }
    # Assigned directly: $( ) around it would unroll the DoubleCollection into an object[] the property rejects.
    if ($State -eq 'Idle' -or $busy) { $u.DropZoneRect.StrokeDashArray = [System.Windows.Media.DoubleCollection]::Parse('5 4') }
    else { $u.DropZoneRect.StrokeDashArray = $null }
    $edge = switch ($State) { 'Validated' { '#6CB76C' } 'NeedsAttention' { '#E0A040' } 'Failed' { '#E07060' } default { '#B9B9B9' } }
    $u.DropZoneRect.Stroke = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($edge)
}

function Set-AutoPackageBusy
{
    # Locks the actions that would collide with a run, and starts / stops the progress indicators.
    param([bool]$Busy)
    $u = $script:ui
    $script:AutoPackageRunning = $Busy
    foreach ($c in @($u.BtnAutoPackage, $u.BtnImportInstaller, $u.BtnGenerate, $u.BtnIntunePublish, $u.MenuNew, $u.MenuOpen, $u.BtnInstallAutoFill)) { $c.IsEnabled = -not $Busy }
    if ($Busy)
    {
        $u.BtnProbeSandbox.IsEnabled = $false
        $u.BtnOpenReport.Visibility  = 'Collapsed'
        $script:AutoPackageStarted = Get-Date
        $script:AutoPackageStep = ''
        $u.DropElapsed.Text = '0:00 elapsed'
        $script:ElapsedTimer.Start()
        $script:Window.TaskbarItemInfo.ProgressState = 'Indeterminate'
        $script:Window.Cursor = [System.Windows.Input.Cursors]::AppStarting
    }
    else
    {
        $script:ElapsedTimer.Stop()
        $script:AutoPackageStarted = $null
        $script:Window.Cursor = $null
        Update-FieldStates
    }
}

function Show-DefinitionInUi
{
    # Loads a definition into the tabs. For EXE installers it also selects the engine preset, then puts back the
    # arguments that were worked out (selecting a preset rewrites the argument boxes).
    param([Parameter(Mandatory)]$Def, [string]$Engine)
    Set-UiDefinition -d $Def
    if ($Def.Install.Type -eq 'EXE' -and $Engine)
    {
        $keys = @($script:SilentPresets.Keys)
        $idx = [Array]::IndexOf($keys, $Engine); if ($idx -lt 0) { $idx = [Array]::IndexOf($keys, 'Unknown') }
        $script:ui.InstallPreset.SelectedIndex = $idx
        $script:ui.InstallArgs.Text   = "$($Def.Install.Arguments)"
        $script:ui.UninstallArgs.Text = "$($Def.Uninstall.Arguments)"
    }
}

function Start-AutoPackageFromUi
{
    # GUI wrapper for Invoke-AutoPackage. The tabs fill in as soon as the file has been read and again as the sandbox
    # learns more; the drop card shows the current step, an elapsed timer and finally the result.
    param([Parameter(Mandatory)][string]$Path)
    if ($script:AutoPackageRunning) { Write-PackagerLog 'An auto-package run is already in progress.' -Level Warn; return }
    $sandbox = $false
    if (-not $NoSandbox) { $sandbox = [bool](Test-WindowsSandbox) }
    $leaf = Split-Path -Path $Path -Leaf
    $base = Get-UiDefinition

    $script:ui.Tabs.SelectedIndex = 0
    Set-AutoPackageBusy $true
    Set-DropZone -Title "Packaging $leaf" -Detail 'Reading the file...' -State Busy
    $script:ui.StatusText.Text = "Auto-packaging $leaf"
    $onProgress = {
        param($Stage, $Message, $Definition, $Info)
        $script:AutoPackageStep = $(switch ($Stage) { 'Reading' { 'reading' } 'Read' { 'read' } 'Probing' { 'Windows Sandbox' } 'Probed' { 'worked out' } 'Building' { 'building' } 'Validating' { 'end-to-end test' } default { '' } })
        if ($script:AutoPackageStarted)
        {
            $e = (Get-Date) - $script:AutoPackageStarted
            $script:ui.DropElapsed.Text = ('{0}:{1:00} elapsed  -  {2}' -f [int][Math]::Floor($e.TotalMinutes), $e.Seconds, $script:AutoPackageStep)
        }
        Set-DropZone -Detail $Message -State Busy
        $script:ui.StatusText.Text = $Message
        if ($Definition)
        {
            $engine = ''
            if ($Info) { $engine = "$($Info.Engine)" }
            Show-DefinitionInUi -Def $Definition -Engine $engine
            $script:ui.BtnProbeSandbox.IsEnabled = $false
        }
        Invoke-UiRefresh
    }
    try
    {
        $confirm = { param($root) Confirm-Action -Text "A package already exists at`n$root`n`nRebuild it?" -Title 'Auto-package' }
        $ctx = Invoke-AutoPackage -Path $Path -BaseDefinition $base -NoSandbox:(-not $sandbox) -SkipValidation:$SkipValidation -Force:([bool]$script:ui.OutOverwrite.IsChecked) -ConfirmOverwrite $confirm -OnProgress $onProgress
        $def = $ctx.Definition
        $engine = ''
        if ($ctx.Info) { $engine = "$($ctx.Info.Engine)" }
        Show-DefinitionInUi -Def $def -Engine $engine
        $script:CurrentDefinitionPath = $null
        $script:Window.Title = 'PSADT Packager'
        if ($ctx.PackageRoot)
        {
            $script:LastOutputPath = $ctx.PackageRoot
            $script:CurrentDefinitionPath = Join-Path $ctx.PackageRoot 'Package.json'
            $script:Window.Title = "PSADT Packager - $(Split-Path -Path $ctx.PackageRoot -Leaf)"
        }
        foreach ($w in @($ctx.Warnings)) { Write-PackagerLog $w -Level Warn }
        $label = "$("$($def.App.Name) $($def.App.Version)".Trim())"
        $warnings = ''
        if (@($ctx.Warnings).Count -gt 0) { $warnings = "`n`n- " + (@($ctx.Warnings) -join "`n- ") }
        switch ($ctx.Status)
        {
            'Validated'
            {
                Set-DropZone -Title "Validated: $label" -State Validated -Detail ("Installed, detected, uninstalled and confirmed gone in Windows Sandbox as SYSTEM, the way Intune runs it. The package is in $($ctx.PackageRoot); every tab shows what was worked out." + $warnings)
                $script:Window.TaskbarItemInfo.ProgressState = 'Normal'
            }
            'Built'
            {
                Set-DropZone -Title "Built: $label" -State Built -Detail ("The package is in $($ctx.PackageRoot), but it was not tested end to end: $("$($ctx.ValidationNote)".TrimEnd('.'))." + $warnings)
                $script:Window.TaskbarItemInfo.ProgressState = 'Normal'
            }
            default
            {
                Set-DropZone -Title "Needs attention: $(if ($label) { $label } else { $leaf })" -State NeedsAttention -Detail ("Check these before deploying; the tabs show what was worked out so far." + $warnings)
                $script:Window.TaskbarItemInfo.ProgressState = 'Paused'
            }
        }
        $script:Window.TaskbarItemInfo.ProgressValue = 1
        $script:LastReportPath = $ctx.ReportPath
        if ($ctx.ReportPath) { $script:ui.BtnOpenReport.Visibility = 'Visible' }
        $script:ui.StatusText.Text = "Auto-package: $($ctx.Status) - $leaf"
        if (-not $script:Window.IsActive) { $script:Window.Activate() | Out-Null }
    }
    catch
    {
        Write-PackagerLog "Auto-package failed: $($_.Exception.Message)" -Level Error
        Set-DropZone -Title "Auto-package failed: $leaf" -Detail $_.Exception.Message -State Failed
        $script:ui.StatusText.Text = 'Auto-package failed'
        $script:Window.TaskbarItemInfo.ProgressState = 'Error'
        $script:Window.TaskbarItemInfo.ProgressValue = 1
    }
    finally
    {
        Set-AutoPackageBusy $false
    }
}

function Add-ListItems
{
    param($ListBox, [string[]]$Items)
    foreach ($i in @($Items | Where-Object { $_ }))
    {
        if (@($ListBox.Items) -notcontains $i) { [void]$ListBox.Items.Add($i) }
    }
    Update-InstallFileChoices
}

function Remove-ListSelection
{
    param($ListBox)
    foreach ($i in @($ListBox.SelectedItems)) { $ListBox.Items.Remove($i) }
    Update-InstallFileChoices
}

function Save-DefinitionFromUi
{
    param([switch]$AskPath)
    $path = $script:CurrentDefinitionPath
    if ($AskPath -or -not $path)
    {
        $def = Get-UiDefinition
        $suggest = (Get-PackageFolderName -Def $def) + '.json'
        $path = Select-SaveDialog -Title 'Save package definition' -Filter 'Package definition (*.json)|*.json' -FileName $suggest
        if (-not $path) { return }
    }
    try
    {
        Save-PackageDefinition -Def (Get-UiDefinition) -Path $path
        $script:CurrentDefinitionPath = $path
        $script:Window.Title = "PSADT Packager - $([System.IO.Path]::GetFileName($path))"
        Write-PackagerLog "Saved definition to $path"
    }
    catch
    {
        Write-PackagerLog "Save failed: $($_.Exception.Message)" -Level Error
        Show-Message -Text $_.Exception.Message -Title 'Save definition' -Icon Error
    }
}

function Open-DefinitionIntoUi
{
    param([string]$Path)
    try
    {
        $def = Read-PackageDefinition -Path $Path
        Set-UiDefinition -d $def
        $script:CurrentDefinitionPath = $Path
        $script:Window.Title = "PSADT Packager - $([System.IO.Path]::GetFileName($Path))"
        Write-PackagerLog "Loaded definition $Path"
    }
    catch
    {
        Write-PackagerLog "Could not load definition: $($_.Exception.Message)" -Level Error
        Show-Message -Text $_.Exception.Message -Title 'Open definition' -Icon Error
    }
}

function Read-PackagerSettings
{
    try
    {
        if (Test-Path -LiteralPath $script:SettingsPath)
        {
            $s = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
            if ($s.Destination)      { $script:ui.OutDestination.Text   = "$($s.Destination)" }
            if ($s.IntuneWinAppUtil) { $script:ui.OutIntuneWinTool.Text = "$($s.IntuneWinAppUtil)" }
            if ($s.Author)           { $script:ui.AppAuthor.Text        = "$($s.Author)" }
            if ($s.TenantId)         { $script:ui.IntTenantId.Text      = "$($s.TenantId)" }
            if ($s.ClientId)         { $script:ui.IntClientId.Text      = "$($s.ClientId)" }
        }
    }
    catch { }
    if (-not $script:ui.OutIntuneWinTool.Text)
    {
        $tool = Resolve-IntuneWinAppUtil
        if ($tool) { $script:ui.OutIntuneWinTool.Text = $tool }
    }
}

function Save-PackagerSettings
{
    try
    {
        if (-not (Test-Path -LiteralPath $script:AppDataDir)) { New-Item -ItemType Directory -Path $script:AppDataDir -Force | Out-Null }
        [pscustomobject]@{
            Destination      = $script:ui.OutDestination.Text.Trim()
            IntuneWinAppUtil = $script:ui.OutIntuneWinTool.Text.Trim()
            Author           = $script:ui.AppAuthor.Text.Trim()
            TenantId         = $script:ui.IntTenantId.Text.Trim()
            ClientId         = $script:ui.IntClientId.Text.Trim()
        } | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    }
    catch { }
}

# ---- Populate combo boxes
$script:ui.InstallType.ItemsSource     = $script:InstallTypeLabels
$script:ui.UninstallType.ItemsSource   = $script:UninstallTypeLabels
$script:ui.DetectType.ItemsSource      = $script:DetectTypeLabels
$script:ui.DetectMatchMode.ItemsSource = $script:MatchModeCodes
$script:ui.UninstallAppType.ItemsSource= $script:AppTypeCodes
$script:ui.AppArch.ItemsSource         = $script:ArchChoices
$script:ui.OutDeployMode.ItemsSource   = $script:DeployModeChoices
$script:ui.InstallPreset.ItemsSource   = @($script:SilentPresets.Values | ForEach-Object { $_.Label })
$script:ui.IntRunAs.ItemsSource        = $script:RunAsLabels
$script:ui.IntRestart.ItemsSource      = $script:RestartLabels
$script:ui.IntMinOs.ItemsSource        = $script:MinOsLabels
$script:ui.IntArch.ItemsSource         = $script:ArchChoicesIntune

# ---- Event wiring
$script:ui.MenuNew.Add_Click({
    if (Confirm-Action -Text 'Clear all fields and start a new definition?')
    {
        $script:CurrentDefinitionPath = $null
        $script:Window.Title = 'PSADT Packager'
        $dest = $script:ui.OutDestination.Text
        $tool = $script:ui.OutIntuneWinTool.Text
        Set-UiDefinition -d (New-PackageDefinition)
        $script:ui.OutDestination.Text = $dest
        $script:ui.OutIntuneWinTool.Text = $tool
    }
})
$script:ui.MenuOpen.Add_Click({
    $p = Select-FileDialog -Title 'Open package definition' -Filter 'Package definition (*.json)|*.json|All files (*.*)|*.*'
    if ($p.Count -gt 0) { Open-DefinitionIntoUi -Path $p[0] }
})
$script:ui.MenuSave.Add_Click({ Save-DefinitionFromUi })
$script:ui.MenuSaveAs.Add_Click({ Save-DefinitionFromUi -AskPath })
$script:ui.MenuExit.Add_Click({ $script:Window.Close() })
$script:ui.MenuAbout.Add_Click({
    Show-Message -Text "PSADT Packager $script:PackagerVersion`n`nBuilds PSAppDeployToolkit v4 packages, Intune detection scripts and .intunewin files from a JSON definition.`n`nToolkit cache: $script:ModuleCache`nSettings: $script:SettingsPath"
})

$script:ui.BtnImportInstaller.Add_Click({
    $p = Select-FileDialog -Title 'Select the installer' -Filter 'Installers and scripts (*.msi;*.exe;*.msix;*.appx;*.msixbundle;*.appxbundle;*.ps1;*.cmd;*.bat;*.vbs)|*.msi;*.exe;*.msix;*.appx;*.msixbundle;*.appxbundle;*.ps1;*.cmd;*.bat;*.vbs|All files (*.*)|*.*'
    if ($p.Count -gt 0) { Import-InstallerIntoUi -Path $p[0] }
})
$script:ui.BtnOpenReport.Add_Click({
    if ($script:LastReportPath -and (Test-Path -LiteralPath $script:LastReportPath)) { Start-Process -FilePath $script:LastReportPath }
})
$script:ui.BtnAutoPackage.Add_Click({
    $p = Select-FileDialog -Title 'Auto-package: pick an installer, script or .zip (drag folders onto the window)' -Filter 'Installers, scripts and archives (*.msi;*.exe;*.msix;*.appx;*.msixbundle;*.appxbundle;*.ps1;*.cmd;*.bat;*.vbs;*.zip)|*.msi;*.exe;*.msix;*.appx;*.msixbundle;*.appxbundle;*.ps1;*.cmd;*.bat;*.vbs;*.zip|All files (*.*)|*.*'
    if ($p.Count -gt 0) { Start-AutoPackageFromUi -Path $p[0] }
})

# Drop anything on the window. Preview events, so text boxes don't take the file as text; the run starts once the drop
# has completed, so Explorer is not left waiting on it.
$script:Window.Add_PreviewDragOver({
    param($dragSource, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop) -and -not $script:AutoPackageRunning)
    {
        $e.Effects = [System.Windows.DragDropEffects]::Copy
        # Light up the drop card while something is being dragged over the window (its own edge comes back after).
        if (-not $script:DropEdge) { $script:DropEdge = $script:ui.DropZoneRect.Stroke }
        $script:ui.DropZoneRect.Stroke = $script:Window.FindResource('Focus')
        $script:ui.DropZoneRect.Fill   = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#F4F7FC')
    }
    else { $e.Effects = [System.Windows.DragDropEffects]::None }
    $e.Handled = $true
})
$script:Window.Add_PreviewDragLeave({
    $script:ui.DropZoneRect.Fill = [System.Windows.Media.Brushes]::White
    if ($script:DropEdge) { $script:ui.DropZoneRect.Stroke = $script:DropEdge; $script:DropEdge = $null }
})
$script:Window.Add_PreviewDrop({
    param($dragSource, $e)
    $script:ui.DropZoneRect.Fill = [System.Windows.Media.Brushes]::White
    if ($script:DropEdge) { $script:ui.DropZoneRect.Stroke = $script:DropEdge; $script:DropEdge = $null }
    if (-not $e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
    $e.Handled = $true
    $dropped = @($e.Data.GetData([System.Windows.DataFormats]::FileDrop))
    if ($dropped.Count -eq 0) { return }
    if ($dropped.Count -gt 1) { Write-PackagerLog "Several items dropped; packaging the first: $($dropped[0])" -Level Warn }
    $script:PendingDrop = "$($dropped[0])"
    [void]$script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
        $p = $script:PendingDrop
        $script:PendingDrop = $null
        if ($p) { Start-AutoPackageFromUi -Path $p }
    })
})

$script:ui.BtnInstallAutoFill.Add_Click({
    $name = "$($script:ui.InstallFile.Text)".Trim()
    if (-not $name) { Show-Message -Text 'Select an installer file first.' -Icon Warning; return }
    $leaf = Split-Path -Path $name -Leaf
    $match = $null
    foreach ($src in @($script:ui.FilesList.Items))
    {
        $s = "$src"
        if ($s.EndsWith('\*')) { $c = Join-Path $s.Substring(0, $s.Length - 2) $name; if (Test-Path -LiteralPath $c -PathType Leaf) { $match = $c; break } }
        elseif (Test-Path -LiteralPath $s -PathType Container) { $c = Join-Path (Split-Path -Path $s -Parent) $name; if (Test-Path -LiteralPath $c -PathType Leaf) { $match = $c; break } }
        elseif ((Split-Path -Path $s -Leaf) -ieq $leaf) { $match = $s; break }
    }
    if (-not $match) { Show-Message -Text "Could not find '$name' among the source files." -Icon Warning; return }
    Import-InstallerIntoUi -Path $match
})

$script:ui.BtnFilesAdd.Add_Click({ Add-ListItems -ListBox $script:ui.FilesList -Items (Select-FileDialog -Title 'Add files to Files\' -Multi) })
$script:ui.BtnFilesAddFolder.Add_Click({ $f = Select-FolderDialog -Description 'Folder to copy into Files\ (as a subfolder)'; if ($f) { Add-ListItems -ListBox $script:ui.FilesList -Items @($f) } })
$script:ui.BtnFilesAddContents.Add_Click({ $f = Select-FolderDialog -Description 'Folder whose contents go into Files\'; if ($f) { Add-ListItems -ListBox $script:ui.FilesList -Items @("$f\*") } })
$script:ui.BtnFilesRemove.Add_Click({ Remove-ListSelection -ListBox $script:ui.FilesList })
$script:ui.BtnSupportAdd.Add_Click({ Add-ListItems -ListBox $script:ui.SupportList -Items (Select-FileDialog -Title 'Add files to SupportFiles\' -Multi) })
$script:ui.BtnSupportAddFolder.Add_Click({ $f = Select-FolderDialog -Description 'Folder to copy into SupportFiles\ (as a subfolder)'; if ($f) { Add-ListItems -ListBox $script:ui.SupportList -Items @($f) } })
$script:ui.BtnSupportAddContents.Add_Click({ $f = Select-FolderDialog -Description 'Folder whose contents go into SupportFiles\'; if ($f) { Add-ListItems -ListBox $script:ui.SupportList -Items @("$f\*") } })
$script:ui.BtnSupportRemove.Add_Click({ Remove-ListSelection -ListBox $script:ui.SupportList })

$script:ui.InstallType.Add_SelectionChanged({ Update-FieldStates })
$script:ui.UninstallType.Add_SelectionChanged({ Update-FieldStates })
$script:ui.DetectType.Add_SelectionChanged({ Update-FieldStates })
$script:ui.ShowWelcome.Add_Click({ Update-FieldStates })
$script:ui.AllowDefer.Add_Click({ Update-FieldStates })
$script:ui.OutBuildIntuneWin.Add_Click({ Update-FieldStates })
$script:ui.InstallPreset.Add_SelectionChanged({
    $idx = $script:ui.InstallPreset.SelectedIndex
    if ($idx -lt 0) { return }
    $preset = @($script:SilentPresets.Values)[$idx]
    if ($preset.Install) { $script:ui.InstallArgs.Text = $preset.Install }
    if ($preset.Uninstall -and (Get-ComboCode $script:ui.UninstallType $script:UninstallTypeCodes 'MSI') -in @('Name', 'EXE') -and -not $script:ui.UninstallArgs.Text.Trim())
    {
        $script:ui.UninstallArgs.Text = $preset.Uninstall
    }
})

$script:ui.BtnProbeSandbox.Add_Click({
    $def = Get-UiDefinition
    if ($def.Install.Type -notin @('EXE', 'Script')) { Show-Message -Text 'The sandbox probe is for EXE installers and scripts.' -Icon Information; return }
    $name = "$($def.Install.File)".Trim()
    if (-not $name) { Show-Message -Text 'Select the installer file first (Source files tab, then Install tab).' -Icon Warning; return }
    # Where the file comes from decides what the sandbox gets: a folder source ships whole, a single file ships alone.
    $installer = $null; $sourceRoot = $null; $whole = $false
    foreach ($src in @($def.Sources.Files))
    {
        $s = "$src"
        if ($s.EndsWith('\*')) { $dir = $s.Substring(0, $s.Length - 2); $c = Join-Path $dir $name; if (Test-Path -LiteralPath $c -PathType Leaf) { $installer = $c; $sourceRoot = $dir; $whole = $true; break } }
        elseif (Test-Path -LiteralPath $s -PathType Container) { $c = Join-Path (Split-Path -Path $s -Parent) $name; if (Test-Path -LiteralPath $c -PathType Leaf) { $installer = $c; $sourceRoot = Split-Path -Path $s -Parent; $whole = $true; break } }
        elseif ((Split-Path -Path $s -Leaf) -ieq (Split-Path -Path $name -Leaf) -and (Test-Path -LiteralPath $s -PathType Leaf)) { $installer = $s; $sourceRoot = Split-Path -Path $s -Parent; break }
    }
    if (-not $installer) { Show-Message -Text "Could not find '$name' among the source files." -Icon Warning; return }
    if (-not (Test-WindowsSandbox))
    {
        Show-Message -Text "Windows Sandbox is not available on this PC.`n`nEnable Windows Sandbox in Windows Features, reboot and try again." -Title 'Find switches' -Icon Warning
        return
    }

    $engine = 'Script'
    $uninstallArgs = ''
    if ($def.Install.Type -eq 'EXE')
    {
        $engine = 'Unknown'
        try { $engine = Get-InstallerEngine -Path $installer } catch { }
        $candidates = @(Get-SilentCandidates -Path $installer -Engine $engine -CurrentArgs $def.Install.Arguments -Max 4)
        $preset = $script:SilentPresets[$engine]
        if ($preset) { $uninstallArgs = $preset.Uninstall }
        $msg = "Installer: $installer`nEngine: $engine`n`nEach candidate runs in a fresh Windows Sandbox as SYSTEM (like Intune; about 1-3 minutes each, no window opens): the installer with those switches, what it registers and creates, your detection script, and the uninstall.`n`nCandidates, in order:`n  " + ($candidates -join "`n  ") + "`n`nContinue?"
    }
    else
    {
        $candidates = @("$($def.Install.Arguments)")
        $msg = "Script: $installer`n`nRuns it once in a fresh Windows Sandbox as SYSTEM (like Intune; no window opens) and records what it creates, so detection and uninstall can be derived from that.`n`nContinue?"
    }
    if (-not (Confirm-Action -Text $msg -Title 'Find switches in Sandbox')) { return }

    $detection = $null
    if ($def.Detection.Type -ne 'Script' -or "$($def.Detection.Script)".Trim()) { try { $detection = New-DetectionScript -Def $def } catch { } }
    $success = @($def.Install.SuccessExitCodes | Where-Object { "$_" -match '^-?\d+$' } | ForEach-Object { [int]$_ }) + @($def.Install.RebootExitCodes | Where-Object { "$_" -match '^-?\d+$' } | ForEach-Object { [int]$_ })
    if ($success.Count -eq 0) { $success = @(0, 3010, 1641) }

    $script:ui.BtnProbeSandbox.IsEnabled = $false
    $script:Window.Cursor = [System.Windows.Input.Cursors]::AppStarting
    try
    {
        $results = @(Invoke-SandboxProbe -InstallerPath $installer -SourceRoot $sourceRoot -CopyWholeSource:$whole -Candidates $candidates -DetectionScript $detection -UninstallArgs $uninstallArgs -AppNameHint $def.App.Name -SuccessCodes $success -HelpSwitch $(if ($def.Install.Type -eq 'EXE') { '/?' } else { '' }))
        $summary = Get-ProbeSummary -Results $results
        foreach ($line in ($summary -split "`n")) { Write-PackagerLog $line }
        $win = @($results | Where-Object { $_.InstallSucceeded }) | Select-Object -First 1
        if ($win)
        {
            if (Confirm-Action -Text "$summary`n`nApply these to the Install, Uninstall and Detection tabs?" -Title 'Sandbox result')
            {
                $current = Get-UiDefinition
                [void](Set-DefinitionFromProbe -Def $current -Result $win)
                Set-UiDefinition -d $current
                $keys = @($script:SilentPresets.Keys)
                $idx = [Array]::IndexOf($keys, $engine); if ($idx -lt 0) { $idx = [Array]::IndexOf($keys, 'Unknown') }
                $script:ui.InstallPreset.SelectedIndex = $idx
                $script:ui.InstallArgs.Text = "$($win.Candidate)"
                Write-PackagerLog 'Applied the sandbox result to the definition.'
            }
        }
        else
        {
            Show-Message -Text "$summary`n`nThe help output above (if any) may name the right switch - enter it in Arguments and run the probe again to verify it." -Title 'Sandbox result' -Icon Warning
        }
    }
    catch
    {
        Write-PackagerLog "Sandbox probe failed: $($_.Exception.Message)" -Level Error
        Show-Message -Text $_.Exception.Message -Title 'Find switches' -Icon Error
    }
    finally
    {
        $script:Window.Cursor = $null
        $script:ui.BtnProbeSandbox.IsEnabled = $true
    }
})

$script:ui.BtnDetectPreview.Add_Click({
    try
    {
        $script:ui.DetectPreview.Text = New-DetectionScript -Def (Get-UiDefinition)
        $script:ui.DetectTestResult.Text = ''
    }
    catch { Show-Message -Text $_.Exception.Message -Title 'Detection preview' -Icon Error }
})
$script:ui.BtnDetectTest.Add_Click({
    try
    {
        $code = New-DetectionScript -Def (Get-UiDefinition)
        $script:ui.DetectPreview.Text = $code
        $tmp = Join-Path $env:TEMP ("PsadtPackager-Detect-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        Write-Utf8File -Path $tmp -Content $code
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1
        $rc  = $LASTEXITCODE
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $text = (@($out) -join ' ').Trim()
        if ($rc -eq 0 -and $text) { $script:ui.DetectTestResult.Text = "DETECTED on this PC - $text"; $script:ui.DetectTestResult.Foreground = 'DarkGreen' }
        else { $script:ui.DetectTestResult.Text = "Not detected on this PC (exit $rc)$(if ($text) { " - $text" })"; $script:ui.DetectTestResult.Foreground = 'Firebrick' }
        Write-PackagerLog "Detection test: $($script:ui.DetectTestResult.Text)"
    }
    catch { Show-Message -Text $_.Exception.Message -Title 'Detection test' -Icon Error }
})

$script:ui.BtnBrowseDest.Add_Click({ $f = Select-FolderDialog -Description 'Destination folder for generated packages'; if ($f) { $script:ui.OutDestination.Text = $f } })
$script:ui.BtnBrowseTool.Add_Click({ $p = Select-FileDialog -Title 'Locate IntuneWinAppUtil.exe' -Filter 'IntuneWinAppUtil.exe|IntuneWinAppUtil.exe|Executables (*.exe)|*.exe'; if ($p.Count -gt 0) { $script:ui.OutIntuneWinTool.Text = $p[0] } })
$script:ui.BtnDownloadTool.Add_Click({
    if (-not (Confirm-Action -Text "Download IntuneWinAppUtil.exe from`n$script:IntuneWinUrl`n`ninto $script:AppDataDir ?")) { return }
    try { $script:ui.OutIntuneWinTool.Text = Get-IntuneWinAppUtil }
    catch { Write-PackagerLog "Download failed: $($_.Exception.Message)" -Level Error; Show-Message -Text $_.Exception.Message -Title 'Download' -Icon Error }
})
$script:ui.BtnPreviewScript.Add_Click({
    try
    {
        $def = Get-UiDefinition
        $script:ui.OutPreview.Text = "# Preview of the generated Variables and Functions sections. The toolkit's own header and bootstrap are added at build time.`r`n`r`n" + (New-DeploymentSections -Def $def)
    }
    catch { Show-Message -Text $_.Exception.Message -Title 'Preview' -Icon Error }
})
$script:ui.BtnOpenOutput.Add_Click({
    $p = $script:LastOutputPath
    if (-not $p) { $p = $script:ui.OutDestination.Text.Trim() }
    if ($p -and (Test-Path -LiteralPath $p)) { Start-Process -FilePath explorer.exe -ArgumentList "`"$p`"" } else { Show-Message -Text 'Nothing has been generated yet.' -Icon Information }
})
$script:ui.BtnGenerate.Add_Click({
    $def = Get-UiDefinition
    $problems = Test-PackageDefinition -Def $def
    if ($problems.Count -gt 0)
    {
        Show-Message -Text ("Fix these before generating:`n`n - " + ($problems -join "`n - ")) -Title 'Definition incomplete' -Icon Warning
        return
    }
    $root = Join-Path $def.Output.Destination (Get-PackageFolderName -Def $def)
    $overwrite = [bool]$script:ui.OutOverwrite.IsChecked
    if ((Test-Path -LiteralPath (Join-Path $root 'Package')) -and -not $overwrite)
    {
        if (-not (Confirm-Action -Text "$root\Package already exists.`n`nDelete it and rebuild?")) { return }
        $overwrite = $true
    }
    $script:ui.BtnGenerate.IsEnabled = $false
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try
    {
        $out = Invoke-PackageBuild -Def $def -Force:$overwrite
        $script:LastOutputPath = $out
        Save-PackagerSettings
        if ($script:CurrentDefinitionPath) { Save-PackageDefinition -Def $def -Path $script:CurrentDefinitionPath }
        $script:ui.OutPreview.Text = [System.IO.File]::ReadAllText((Join-Path $out 'README.md'))
        Show-Message -Text "Package generated:`n$out`n`nREADME.md lists the Intune settings for this app."
    }
    catch
    {
        Write-PackagerLog $_.Exception.Message -Level Error
        Show-Message -Text $_.Exception.Message -Title 'Generate failed' -Icon Error
    }
    finally
    {
        $script:Window.Cursor = $null
        $script:ui.BtnGenerate.IsEnabled = $true
    }
})

# ---- Intune tab
$script:IntuneAutoFilled = @{}

function Set-IntuneAutoField
{
    # Fills a box with a derived value, and keeps it in step with the other tabs until the user edits it.
    param([Parameter(Mandatory)]$Box, [string]$Value, [Parameter(Mandatory)][string]$Key)
    $current = "$($Box.Text)"
    $isAuto  = $script:IntuneAutoFilled.ContainsKey($Key) -and $script:IntuneAutoFilled[$Key] -ceq $current
    if ($current.Trim() -and -not $isAuto) { return }   # the user typed their own value; leave it alone
    $Box.Text = $Value
    $script:IntuneAutoFilled[$Key] = $Value
}

function Update-IntuneAutoFields
{
    # Everything the other tabs already imply, filled in without the user retyping it.
    $u   = $script:ui
    $def = Get-UiDefinition
    $auto = New-IntuneAppPayload -Def $def -DetectionScript '#'
    Set-IntuneAutoField -Box $u.IntDisplayName  -Key 'DisplayName'  -Value (Get-IntuneDisplayName -Def $def)
    Set-IntuneAutoField -Box $u.IntPublisher    -Key 'Publisher'    -Value "$($def.App.Vendor)".Trim()
    Set-IntuneAutoField -Box $u.IntDeveloper    -Key 'Developer'    -Value "$($def.App.Vendor)".Trim()
    Set-IntuneAutoField -Box $u.IntOwner        -Key 'Owner'        -Value "$($def.App.Author)".Trim()
    Set-IntuneAutoField -Box $u.IntDescription  -Key 'Description'  -Value $auto.description
    Set-IntuneAutoField -Box $u.IntInstallCmd   -Key 'InstallCmd'   -Value (Get-IntuneInstallCommand -Def $def)
    Set-IntuneAutoField -Box $u.IntUninstallCmd -Key 'UninstallCmd' -Value (Get-IntuneUninstallCommand -Def $def)
    Set-IntuneAutoField -Box $u.IntArch         -Key 'Arch'         -Value (Get-IntuneArchitectures -Def $def)
}

$script:ui.Tabs.Add_SelectionChanged({
    param($EventSender, $EventArgs)
    # SelectionChanged bubbles up from the combo boxes inside each tab, so only react to the TabControl's own event.
    if ($EventArgs.Source -ne $script:ui.Tabs) { return }
    if ($script:ui.Tabs.SelectedItem -eq $script:ui.TabIntune) { try { Update-IntuneAutoFields } catch { } }
})

$script:ui.BtnIntuneReset.Add_Click({
    $u = $script:ui
    foreach ($box in @($u.IntDisplayName, $u.IntPublisher, $u.IntDescription, $u.IntDeveloper, $u.IntOwner, $u.IntInstallCmd, $u.IntUninstallCmd)) { $box.Text = '' }
    $u.IntArch.Text = ''
    $script:IntuneAutoFilled = @{}
    Update-IntuneAutoFields
    Write-PackagerLog 'Intune fields reset to the values derived from the other tabs.'
})

$script:ui.BtnGraphConnect.Add_Click({
    try
    {
        $script:ui.BtnGraphConnect.IsEnabled = $false
        $script:ui.IntConnStatus.Text = 'Waiting for sign-in...'
        $script:GraphPromptSink = {
            param($Dc)
            $script:ui.IntConnStatus.Text = "Enter code $($Dc.user_code) in the browser (copied to your clipboard)."
            Invoke-UiRefresh
        }
        $tok = Connect-IntuneGraph -TenantId $script:ui.IntTenantId.Text.Trim() -ClientId $script:ui.IntClientId.Text.Trim()
        $script:ui.IntConnStatus.Text = "Connected as $($tok.Account) - tenant $($tok.TenantId)"
        if (-not $script:ui.IntTenantId.Text.Trim()) { $script:ui.IntTenantId.Text = $tok.TenantId }
    }
    catch
    {
        $script:ui.IntConnStatus.Text = 'Not connected.'
        Write-PackagerLog "Graph sign-in failed: $($_.Exception.Message)" -Level Error
        Show-Message -Text $_.Exception.Message -Title 'Connect to Intune' -Icon Error
    }
    finally
    {
        $script:GraphPromptSink = $null
        $script:ui.BtnGraphConnect.IsEnabled = $true
    }
})

$script:ui.BtnIntunePreview.Add_Click({
    try
    {
        Update-IntuneAutoFields
        $def = Get-UiDefinition
        $script:ui.IntPreview.Text = ConvertTo-IntuneAppJson -Payload (New-IntuneAppPayload -Def $def -DetectionScript (New-DetectionScript -Def $def))
    }
    catch { Show-Message -Text $_.Exception.Message -Title 'Preview app JSON' -Icon Error }
})

$script:ui.BtnIntunePublish.Add_Click({
    Update-IntuneAutoFields
    $def = Get-UiDefinition
    $problems = Test-PackageDefinition -Def $def
    if ($problems.Count -gt 0)
    {
        Show-Message -Text ("Fix these first:`n`n - " + ($problems -join "`n - ")) -Title 'Definition incomplete' -Icon Warning
        return
    }
    $paths = Get-PackagePaths -Def $def
    if (-not (Test-Path -LiteralPath $paths.IntuneWin -PathType Leaf))
    {
        Show-Message -Text "No .intunewin at`n$($paths.IntuneWin)`n`nTick 'Build .intunewin' on the Build tab and generate the package first." -Title 'Publish to Intune' -Icon Warning
        return
    }
    if (-not $script:GraphToken)
    {
        Show-Message -Text 'Connect to your tenant first.' -Title 'Publish to Intune' -Icon Warning
        return
    }
    if (-not (Confirm-Action -Text "Create '$(Get-IntuneDisplayName -Def $def)' in tenant $($script:GraphToken.TenantId)?`n`nNo assignments are created.")) { return }

    $script:ui.BtnIntunePublish.IsEnabled = $false
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try
    {
        $app = Publish-IntuneWin32App -Def $def -IntuneWinPath $paths.IntuneWin
        $script:ui.IntPreview.Text = "Published $($app.DisplayName)`r`nApp id: $($app.Id)`r`n$($app.PortalUrl)"
        if (Confirm-Action -Text "Published '$($app.DisplayName)'.`n`nOpen it in the Intune portal?")
        {
            Start-Process $app.PortalUrl
        }
    }
    catch
    {
        Write-PackagerLog $_.Exception.Message -Level Error
        Show-Message -Text $_.Exception.Message -Title 'Publish failed' -Icon Error
    }
    finally
    {
        $script:Window.Cursor = $null
        $script:ui.BtnIntunePublish.IsEnabled = $true
    }
})

$script:Window.Add_Closing({ Save-PackagerSettings })

# ---- Initial state
Set-UiDefinition -d (New-PackageDefinition)
Read-PackagerSettings
if ($Definition) { Open-DefinitionIntoUi -Path (Resolve-Path -LiteralPath $Definition).Path }
if ($InstallerPath)
{
    # Started with -InstallerPath: auto-package as soon as the window is up.
    $script:StartupInstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
    $script:Window.Add_ContentRendered({
        $p = $script:StartupInstallerPath
        $script:StartupInstallerPath = $null
        if ($p) { Start-AutoPackageFromUi -Path $p }
    })
}
Write-PackagerLog "PSADT Packager $script:PackagerVersion ready (PowerShell $($PSVersionTable.PSVersion)). Drop an installer, script, .zip or folder on this window to auto-package it."
$script:Window.ShowDialog() | Out-Null

#endregion
