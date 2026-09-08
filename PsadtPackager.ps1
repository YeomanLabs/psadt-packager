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

.PARAMETER NoGui
    Build headlessly from -Definition (for CI / repeatable rebuilds).

.PARAMETER Destination
    Overrides Output.Destination from the definition.

.PARAMETER Force
    Overwrite an existing Package folder in headless mode.

.EXAMPLE
    .\PsadtPackager.ps1

.EXAMPLE
    .\PsadtPackager.ps1 -Definition .\examples\7-Zip.json -NoGui -Force

.NOTES
    Works on Windows PowerShell 5.1 and PowerShell 7 (Windows only - WPF).
#>
#Requires -Version 5.1
[CmdletBinding()]
param
(
    [Parameter(Position = 0)]
    [string]$Definition,

    [switch]$NoGui,

    [string]$Destination,

    [switch]$Force
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:PackagerVersion = '1.0.0'
$script:AppDataDir      = Join-Path $env:LOCALAPPDATA 'PsadtPackager'
$script:ModuleCache     = Join-Path $script:AppDataDir 'Modules'
$script:SettingsPath    = Join-Path $script:AppDataDir 'settings.json'
$script:IntuneWinUrl    = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe'
$script:LogSink         = { param($Line, $Level) if ($Level -eq 'Error') { Write-Host $Line -ForegroundColor Red } elseif ($Level -eq 'Warn') { Write-Host $Line -ForegroundColor Yellow } else { Write-Host $Line } }

$script:InstallTypeCodes   = @('MSI', 'EXE', 'Script', 'MSIX', 'Custom')
$script:InstallTypeLabels  = @('MSI (Start-ADTMsiProcess)', 'EXE / setup.exe (Start-ADTProcess)', 'PowerShell script in Files\', 'MSIX / AppX (provisioned)', 'Custom PowerShell (you write the Install phase)')
$script:UninstallTypeCodes = @('MSI', 'Name', 'EXE', 'Script', 'MSIX', 'Custom', 'None')
$script:UninstallTypeLabels= @('MSI product code (Start-ADTMsiProcess)', 'Installed app by name (Uninstall-ADTApplication)', 'Uninstaller EXE on the device (Start-ADTProcess)', 'PowerShell script in Files\', 'MSIX / AppX (remove provisioned + installed)', 'Custom PowerShell (you write the Uninstall phase)', 'None')
$script:DetectTypeCodes    = @('MSI', 'Registry', 'File', 'MSIX', 'Script')
$script:DetectTypeLabels   = @('MSI product code in Uninstall registry', 'Uninstall registry entry by DisplayName', 'File exists (optionally version)', 'MSIX / AppX package', 'Custom script (paste your own)')
$script:MatchModeCodes     = @('Exact', 'Wildcard', 'Regex')
$script:AppTypeCodes       = @('All', 'MSI', 'EXE')
$script:ArchChoices        = @('', 'x64', 'x86', 'ARM64')
$script:DeployModeChoices  = @('Silent', 'Auto', 'Interactive', 'NonInteractive')

$script:SilentPresets = [ordered]@{
    'Inno'              = @{ Label = 'Inno Setup';             Install = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'; Uninstall = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
    'NSIS'              = @{ Label = 'NSIS (Nullsoft)';        Install = '/S';                                            Uninstall = '/S' }
    'InstallShield'     = @{ Label = 'InstallShield';          Install = '/s /v"/qn REBOOT=ReallySuppress"';               Uninstall = '/s /x /v"/qn REBOOT=ReallySuppress"' }
    'WiX'               = @{ Label = 'WiX Burn bundle';        Install = '/quiet /norestart';                             Uninstall = '/uninstall /quiet /norestart' }
    'Squirrel'          = @{ Label = 'Squirrel (Electron)';    Install = '--silent';                                      Uninstall = '--uninstall -s' }
    'InstallAware'      = @{ Label = 'InstallAware';           Install = '/s';                                            Uninstall = '/s MODIFY=FALSE REMOVE=TRUE UNINSTALL=YES' }
    'AdvancedInstaller' = @{ Label = 'Advanced Installer';     Install = '/exenoui /qn';                                  Uninstall = '/x /qn' }
    'MsiWrapper'        = @{ Label = 'msiexec-style wrapper';  Install = '/qn /norestart';                                Uninstall = '/qn /norestart' }
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
        'Script' { if (-not "$($u.File)".Trim()) { $problems += 'Script uninstall needs a .ps1 file name from the Files list.' } }
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
    return $problems
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
    }
    finally { $fs.Dispose() }
    $latin = [System.Text.Encoding]::GetEncoding(28591).GetString($buf)
    $wide  = $latin -replace "`0", ''
    $vi    = (Get-Item -LiteralPath $Path).VersionInfo
    $meta  = "$($vi.FileDescription) $($vi.ProductName) $($vi.Comments) $($vi.InternalName) $($vi.OriginalFilename)"

    if ($latin -match 'Inno Setup' -or $wide -match 'Inno Setup')                                   { return 'Inno' }
    if ($latin -match 'Squirrel' -or $wide -match 'Squirrel')                                       { return 'Squirrel' }
    if ($latin -match 'Nullsoft' -or $latin -match 'NSIS Error' -or $wide -match 'Nullsoft')        { return 'NSIS' }
    if ($meta -match 'InstallShield' -or $latin -match 'InstallShield' -or $wide -match 'InstallShield') { return 'InstallShield' }
    if ($latin -match '\.wixburn' -or $meta -match 'WiX')                                           { return 'WiX' }
    if ($latin -match 'InstallAware' -or $wide -match 'InstallAware')                               { return 'InstallAware' }
    if ($latin -match 'Advanced Installer' -or $wide -match 'Advanced Installer' -or $meta -match 'Advanced Installer') { return 'AdvancedInstaller' }
    if ($latin -match 'MSI Wrapper' -or $wide -match 'MSI Wrapper' -or $wide -match 'msiexec')      { return 'MsiWrapper' }
    return 'Unknown'
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
        return [pscustomobject]@{
            PackageName = "$($identity.Name)"
            Version     = "$($identity.Version)"
            Publisher   = "$($identity.Publisher)"
            DisplayName = $display
            Vendor      = $vendor
        }
    }
    finally { $zip.Dispose() }
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
        Version       = ''
        ProductCode   = ''
        Engine        = ''
        InstallArgs   = ''
        UninstallArgs = ''
        PackageName   = ''
    }
    switch ($ext)
    {
        '.msi'
        {
            $p = Get-MsiProperties -Path $Path
            $info.Type        = 'MSI'
            $info.Vendor      = "$($p['Manufacturer'])".Trim()
            $info.Name        = "$($p['ProductName'])".Trim()
            $info.Version     = Get-CleanVersion "$($p['ProductVersion'])"
            $info.ProductCode = "$($p['ProductCode'])".Trim()
            $info.Engine      = 'MSI'
        }
        '.exe'
        {
            $vi = (Get-Item -LiteralPath $Path).VersionInfo
            $info.Type    = 'EXE'
            $info.Vendor  = "$($vi.CompanyName)".Trim()
            $info.Name    = "$($vi.ProductName)".Trim()
            if (-not $info.Name) { $info.Name = [System.IO.Path]::GetFileNameWithoutExtension($Path) }
            $info.Version = Get-CleanVersion "$($vi.ProductVersion)"
            if (-not $info.Version) { $info.Version = Get-CleanVersion "$($vi.FileVersion)" }
            $info.Engine  = Get-InstallerEngine -Path $Path
            $preset = $script:SilentPresets[$info.Engine]
            if ($preset)
            {
                $info.InstallArgs   = $preset.Install
                $info.UninstallArgs = $preset.Uninstall
            }
        }
        { $_ -in @('.msix', '.appx', '.msixbundle', '.appxbundle') }
        {
            $m = Get-AppxManifestInfo -Path $Path
            $info.Type        = 'MSIX'
            $info.Vendor      = $m.Vendor
            $info.Name        = $m.DisplayName
            $info.Version     = $m.Version
            $info.PackageName = $m.PackageName
            $info.Engine      = 'MSIX'
        }
        '.ps1'
        {
            $info.Type   = 'Script'
            $info.Name   = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            $info.Engine = 'Script'
        }
        default { throw "Unsupported installer type '$ext'. Supported: .msi, .exe, .msix, .appx, .msixbundle, .appxbundle, .ps1" }
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
            $L.Add('    ## Runs in-process, so the script can use every PSADT function and $adtSession.')
            $line = '    & ' + (Get-DirFilesLiteral $i.File)
            if ("$($i.Arguments)".Trim()) { $line += ' ' + $i.Arguments.Trim() }
            $L.Add($line)
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
            $line = '    Uninstall-ADTApplication'
            if ($u.NameIsRegex) { $line += ' -NameMatch ' + (ConvertTo-PsSingleQuoted $u.Name.Trim()) }
            else
            {
                $n = $u.Name.Trim()
                if ($n -match '[\*\?]') { $line += ' -FilterScript { $_.DisplayName -like ' + (ConvertTo-PsSingleQuoted $n) + ' }' }
                else                    { $line += ' -Name ' + (ConvertTo-PsSingleQuoted $n) }
            }
            if ($u.ApplicationType -and $u.ApplicationType -ne 'All') { $line += " -ApplicationType $($u.ApplicationType)" }
            if ("$($u.Arguments)".Trim())
            {
                $L.Add('    ## ArgumentList is used for EXE uninstallers (replaces the arguments in UninstallString); MSI entries get the toolkit defaults.')
                $line += ' -ArgumentList ' + (ConvertTo-PsSingleQuoted $u.Arguments.Trim())
            }
            $L.Add($line)
        }
        'EXE'
        {
            $L.Add('    ## Uninstaller path on the device ($env: variables expand at run time).')
            $L.Add('    $uninstaller = "' + (ConvertTo-PsExpandableString $u.File.Trim()) + '"')
            $L.Add('    if (Test-Path -LiteralPath $uninstaller -PathType Leaf)')
            $L.Add('    {')
            $line = '        Start-ADTProcess -FilePath $uninstaller'
            if ("$($u.Arguments)".Trim()) { $line += ' -ArgumentList ' + (ConvertTo-PsSingleQuoted $u.Arguments.Trim()) }
            $line += ' -WindowStyle Hidden'
            $L.Add($line)
            $L.Add('    }')
            $L.Add('    else')
            $L.Add('    {')
            $L.Add('        Write-ADTLogEntry -Message "Uninstaller not found at [$uninstaller]; nothing to remove." -Severity 2')
            $L.Add('    }')
        }
        'Script'
        {
            $L.Add('    ## Runs in-process, so the script can use every PSADT function and $adtSession.')
            $line = '    & ' + (Get-DirFilesLiteral $u.File.Trim())
            if ("$($u.Arguments)".Trim()) { $line += ' ' + $u.Arguments.Trim() }
            $L.Add($line)
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
    $modeArg = if ($mode -eq 'Auto') { '' } else { " -DeployMode $mode" }
    $success = @($Def.Install.SuccessExitCodes | Where-Object { "$_" -match '^\d+$' })
    $reboot  = @($Def.Install.RebootExitCodes  | Where-Object { "$_" -match '^\d+$' })
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add("# $($a.Vendor) $($a.Name) $($a.Version)".Replace('#  ', '# ').TrimEnd())
    $L.Add('')
    $L.Add("Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by PSADT Packager $script:PackagerVersion using PSAppDeployToolkit $ToolkitVersion.")
    $L.Add('')
    $L.Add('## Intune Win32 app settings')
    $L.Add('')
    $L.Add('| Setting | Value |')
    $L.Add('| --- | --- |')
    $L.Add('| Package source folder (`.intunewin` content) | `Package\` |')
    $L.Add('| Setup file (IntuneWinAppUtil `-s`) | `Invoke-AppDeployToolkit.exe` |')
    $L.Add("| Install command | ``Invoke-AppDeployToolkit.exe -DeploymentType Install$modeArg`` |")
    $L.Add("| Uninstall command | ``Invoke-AppDeployToolkit.exe -DeploymentType Uninstall$modeArg`` |")
    $L.Add('| Install behavior | System |')
    $L.Add('| Device restart behavior | Determine behavior based on return codes |')
    $L.Add("| Detection rule | Use a custom detection script: ``$DetectFileName`` (Run as 32-bit: No, Enforce signature check: No) |")
    $L.Add("| Return codes | Success: $($success -join ', '); Soft reboot: $($reboot -join ', '); Retry: 1618; PSADT: 60012 = deferred by user (map to Failed or Retry), 1602 = cancelled |")
    if ($IntuneWinName) { $L.Add("| Built package | ``Intune\$IntuneWinName`` |") }
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

    $folderName = Get-PackageFolderName -Def $Def
    $root       = Join-Path $Def.Output.Destination $folderName
    $pkg        = Join-Path $root 'Package'
    $filesDir   = Join-Path $pkg 'Files'
    $supportDir = Join-Path $pkg 'SupportFiles'
    $detectName = "Detect-$(Get-SafeName $Def.App.Name).ps1"

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
        $intuneDir = Join-Path $root 'Intune'
        if (-not (Test-Path -LiteralPath $intuneDir)) { New-Item -ItemType Directory -Path $intuneDir -Force | Out-Null }
        $intuneWinName = "$folderName.intunewin"
        $rawOut = Join-Path $intuneDir 'Invoke-AppDeployToolkit.intunewin'
        $final  = Join-Path $intuneDir $intuneWinName
        foreach ($f in @($rawOut, $final)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
        Write-PackagerLog "Building $intuneWinName with $tool"
        $output = & $tool -c $pkg -s 'Invoke-AppDeployToolkit.exe' -o $intuneDir -q 2>&1
        foreach ($line in @($output)) { if ("$line".Trim()) { Write-PackagerLog "  $line" } }
        if (-not (Test-Path -LiteralPath $rawOut)) { throw "IntuneWinAppUtil did not produce $rawOut (exit code $LASTEXITCODE)." }
        Rename-Item -LiteralPath $rawOut -NewName $intuneWinName -Force
        Write-PackagerLog "Created $final"
    }

    Write-Utf8File -Path (Join-Path $root 'README.md') -Content (New-PackageReadme -Def $Def -FolderName $folderName -DetectFileName $detectName -ToolkitVersion "$($mod.Version)" -IntuneWinName $intuneWinName)
    Write-PackagerLog "Done: $root"
    return $root
}

#endregion

#region ---------------------------------------------------------------- Headless entry point

if ($NoGui)
{
    if (-not $Definition) { throw 'Specify -Definition <Package.json> with -NoGui.' }
    try
    {
        $def = Read-PackageDefinition -Path (Resolve-Path -LiteralPath $Definition).Path
        if ($Destination) { $def.Output.Destination = $Destination }
        $out = Invoke-PackageBuild -Def $def -Force:$Force
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
    $args = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Definition) { $args += @('-Definition', $Definition) }
    Start-Process -FilePath $exe -ArgumentList $args
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PSADT Packager" Width="1080" Height="840" MinWidth="960" MinHeight="720"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="12" Background="#F3F3F3">
  <Window.Resources>
    <Style TargetType="Label">
      <Setter Property="Margin" Value="0,2,8,2"/>
      <Setter Property="VerticalAlignment" Value="Top"/>
      <Setter Property="Padding" Value="0,5,0,0"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Margin" Value="0,3,0,3"/>
      <Setter Property="Padding" Value="3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="0,3,0,3"/>
      <Setter Property="Padding" Value="4,3"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,6,14,4"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Margin" Value="6,3,0,3"/>
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="MinWidth" Value="96"/>
    </Style>
    <Style x:Key="Code" TargetType="TextBox">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="AcceptsReturn" Value="True"/>
      <Setter Property="AcceptsTab" Value="True"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="TextWrapping" Value="NoWrap"/>
      <Setter Property="Margin" Value="0,3,0,3"/>
      <Setter Property="Padding" Value="3"/>
      <Setter Property="VerticalContentAlignment" Value="Top"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#5A5A5A"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Margin" Value="0,4,0,4"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Menu DockPanel.Dock="Top">
      <MenuItem Header="_File">
        <MenuItem Name="MenuNew" Header="_New definition"/>
        <MenuItem Name="MenuOpen" Header="_Open definition..."/>
        <MenuItem Name="MenuSave" Header="_Save definition"/>
        <MenuItem Name="MenuSaveAs" Header="Save definition _as..."/>
        <Separator/>
        <MenuItem Name="MenuExit" Header="E_xit"/>
      </MenuItem>
      <MenuItem Header="_Help">
        <MenuItem Name="MenuAbout" Header="_About"/>
      </MenuItem>
    </Menu>
    <StatusBar DockPanel.Dock="Bottom">
      <TextBlock Name="StatusText" Text="Ready"/>
    </StatusBar>
    <Grid Margin="8">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="150" MinHeight="60"/>
      </Grid.RowDefinitions>
      <TabControl Name="Tabs" Grid.Row="0">

        <TabItem Header="  1. Application  ">
          <Grid Margin="12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="150"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Style="{StaticResource Hint}"
                       Text="Start with the installer: 'Read metadata from installer' fills vendor, name, version, product code, silent switches, uninstall and detection from the MSI / EXE / MSIX. Adjust anything afterwards."/>
            <Button Grid.Row="1" Grid.Column="1" Name="BtnImportInstaller" Content="Read metadata from installer..." HorizontalAlignment="Left" Margin="0,0,0,12"/>
            <Label Grid.Row="2" Content="Vendor"/>
            <TextBox Grid.Row="2" Grid.Column="1" Name="AppVendor"/>
            <Label Grid.Row="3" Content="Application name"/>
            <TextBox Grid.Row="3" Grid.Column="1" Name="AppName"/>
            <Label Grid.Row="4" Content="Version"/>
            <TextBox Grid.Row="4" Grid.Column="1" Name="AppVersion" Width="220" HorizontalAlignment="Left"/>
            <Label Grid.Row="5" Content="Architecture"/>
            <ComboBox Grid.Row="5" Grid.Column="1" Name="AppArch" Width="140" HorizontalAlignment="Left" IsEditable="True"/>
            <Label Grid.Row="6" Content="Language"/>
            <TextBox Grid.Row="6" Grid.Column="1" Name="AppLang" Width="80" HorizontalAlignment="Left"/>
            <Label Grid.Row="7" Content="Revision"/>
            <TextBox Grid.Row="7" Grid.Column="1" Name="AppRevision" Width="80" HorizontalAlignment="Left"/>
            <Label Grid.Row="8" Content="Script version"/>
            <TextBox Grid.Row="8" Grid.Column="1" Name="AppScriptVersion" Width="140" HorizontalAlignment="Left"/>
            <Label Grid.Row="9" Content="Script author"/>
            <TextBox Grid.Row="9" Grid.Column="1" Name="AppAuthor" Width="300" HorizontalAlignment="Left"/>
            <TextBlock Grid.Row="10" Grid.Column="1" Style="{StaticResource Hint}" Margin="0,12,0,0"
                       Text="The output folder is named Vendor_Name_Version. Vendor, name and version also drive the PSADT dialog titles and log file names."/>
          </Grid>
        </TabItem>

        <TabItem Header="  2. Source files  ">
          <Grid Margin="12">
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
            <ListBox Grid.Row="2" Name="FilesList" SelectionMode="Extended" FontFamily="Consolas" Margin="0,2,0,10"/>
            <DockPanel Grid.Row="3">
              <TextBlock Style="{StaticResource Section}" Text="SupportFiles\" VerticalAlignment="Center"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="BtnSupportAdd" Content="Add files..."/>
                <Button Name="BtnSupportAddFolder" Content="Add folder..."/>
                <Button Name="BtnSupportAddContents" Content="Add folder contents..."/>
                <Button Name="BtnSupportRemove" Content="Remove selected"/>
              </StackPanel>
            </DockPanel>
            <ListBox Grid.Row="5" Name="SupportList" SelectionMode="Extended" FontFamily="Consolas" Margin="0,2,0,0"/>
          </Grid>
        </TabItem>

        <TabItem Header="  3. Install  ">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <Grid Margin="12">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="170"/>
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
              <ComboBox Grid.Row="1" Grid.Column="1" Name="InstallType" Width="360" HorizontalAlignment="Left"/>
              <Label Grid.Row="2" Content="Installer file"/>
              <DockPanel Grid.Row="2" Grid.Column="1">
                <Button DockPanel.Dock="Right" Name="BtnInstallAutoFill" Content="Auto-fill from file"/>
                <ComboBox Name="InstallFile" IsEditable="True"/>
              </DockPanel>
              <TextBlock Grid.Row="3" Grid.Column="1" Style="{StaticResource Hint}" Text="File name inside Files\ (pick from the list or type a relative path such as Setup\install.exe)."/>
              <Label Grid.Row="4" Content="Arguments"/>
              <DockPanel Grid.Row="4" Grid.Column="1">
                <ComboBox DockPanel.Dock="Right" Name="InstallPreset" Width="200" Margin="6,3,0,3"/>
                <TextBox Name="InstallArgs" FontFamily="Consolas"/>
              </DockPanel>
              <TextBlock Grid.Row="5" Grid.Column="1" Style="{StaticResource Hint}" Name="InstallArgsHint" Text="EXE: silent switches. MSI: extra properties appended to the toolkit's /QN (e.g. ALLUSERS=1 ADDLOCAL=ALL). Script: parameters in PowerShell syntax."/>
              <Label Grid.Row="6" Content="MST transforms"/>
              <TextBox Grid.Row="6" Grid.Column="1" Name="InstallTransforms" FontFamily="Consolas"/>
              <Label Grid.Row="7" Content="MSI product code"/>
              <TextBox Grid.Row="7" Grid.Column="1" Name="InstallProductCode" FontFamily="Consolas" Width="360" HorizontalAlignment="Left"/>
              <Label Grid.Row="8" Content="Processes to close"/>
              <TextBox Grid.Row="8" Grid.Column="1" Name="CloseProcesses"/>
              <TextBlock Grid.Row="9" Grid.Column="1" Style="{StaticResource Hint}" Text="Comma-separated process names without .exe. Optional friendly name with a pipe: winword|Microsoft Word, excel|Microsoft Excel"/>
              <Label Grid.Row="10" Content="Exit codes"/>
              <StackPanel Grid.Row="10" Grid.Column="1" Orientation="Horizontal">
                <Label Content="Success" Padding="0,5,0,0"/>
                <TextBox Name="SuccessCodes" Width="160" FontFamily="Consolas"/>
                <Label Content="Reboot" Margin="16,2,8,2" Padding="0,5,0,0"/>
                <TextBox Name="RebootCodes" Width="160" FontFamily="Consolas"/>
              </StackPanel>
              <Label Grid.Row="11" Content="Dialogs"/>
              <WrapPanel Grid.Row="11" Grid.Column="1">
                <CheckBox Name="ShowWelcome" Content="Welcome / close-apps dialog"/>
                <CheckBox Name="AllowDefer" Content="Allow defer"/>
                <TextBox Name="DeferTimes" Width="40" Margin="0,3,4,3"/>
                <Label Content="times" Padding="0,5,14,0"/>
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
          </ScrollViewer>
        </TabItem>

        <TabItem Header="  4. Uninstall  ">
          <ScrollViewer VerticalScrollBarVisibility="Auto">
            <Grid Margin="12">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="170"/>
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
              <ComboBox Grid.Row="1" Grid.Column="1" Name="UninstallType" Width="360" HorizontalAlignment="Left"/>
              <Label Grid.Row="2" Content="MSI product code"/>
              <TextBox Grid.Row="2" Grid.Column="1" Name="UninstallProductCode" FontFamily="Consolas" Width="360" HorizontalAlignment="Left"/>
              <Label Grid.Row="3" Content="Installed app name"/>
              <DockPanel Grid.Row="3" Grid.Column="1">
                <ComboBox DockPanel.Dock="Right" Name="UninstallAppType" Width="80" Margin="6,3,0,3"/>
                <Label DockPanel.Dock="Right" Content="App type" Margin="12,2,0,2"/>
                <CheckBox DockPanel.Dock="Right" Name="UninstallNameRegex" Content="Regex" Margin="12,6,0,4"/>
                <TextBox Name="UninstallName"/>
              </DockPanel>
              <TextBlock Grid.Row="4" Grid.Column="1" Style="{StaticResource Hint}" Text="DisplayName as shown in Apps and Features. Wildcards (*) are allowed; tick Regex for a .NET regular expression."/>
              <Label Grid.Row="5" Content="Uninstaller / script"/>
              <TextBox Grid.Row="5" Grid.Column="1" Name="UninstallFile" FontFamily="Consolas"/>
              <TextBlock Grid.Row="6" Grid.Column="1" Style="{StaticResource Hint}" Text="EXE method: full path on the device, $env:ProgramFiles etc. allowed. Script method: .ps1 file name inside Files\."/>
              <Label Grid.Row="7" Content="Arguments"/>
              <TextBox Grid.Row="7" Grid.Column="1" Name="UninstallArgs" FontFamily="Consolas"/>
              <Label Grid.Row="8" Content="MSIX package name"/>
              <TextBox Grid.Row="8" Grid.Column="1" Name="UninstallPackageName" FontFamily="Consolas"/>
              <Label Grid.Row="9" Content="Pre-uninstall PowerShell"/>
              <TextBox Grid.Row="9" Grid.Column="1" Name="UninstallPre" Style="{StaticResource Code}" Height="90"/>
              <Label Grid.Row="10" Content="Custom uninstall PowerShell"/>
              <TextBox Grid.Row="10" Grid.Column="1" Name="UninstallCustom" Style="{StaticResource Code}" Height="120"/>
              <Label Grid.Row="11" Content="Post-uninstall PowerShell"/>
              <TextBox Grid.Row="11" Grid.Column="1" Name="UninstallPost" Style="{StaticResource Code}" Height="90"/>
            </Grid>
          </ScrollViewer>
        </TabItem>

        <TabItem Header="  5. Detection  ">
          <Grid Margin="12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="170"/>
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
            <ComboBox Grid.Row="1" Grid.Column="1" Name="DetectType" Width="360" HorizontalAlignment="Left"/>
            <Label Grid.Row="2" Content="MSI product code"/>
            <TextBox Grid.Row="2" Grid.Column="1" Name="DetectProductCode" FontFamily="Consolas" Width="360" HorizontalAlignment="Left"/>
            <Label Grid.Row="3" Content="Minimum version"/>
            <TextBox Grid.Row="3" Grid.Column="1" Name="DetectMinVersion" FontFamily="Consolas" Width="200" HorizontalAlignment="Left"/>
            <Label Grid.Row="4" Content="Display name"/>
            <DockPanel Grid.Row="4" Grid.Column="1">
              <ComboBox DockPanel.Dock="Right" Name="DetectMatchMode" Width="110" Margin="6,3,0,3"/>
              <TextBox Name="DetectDisplayName"/>
            </DockPanel>
            <Label Grid.Row="5" Content="File path"/>
            <DockPanel Grid.Row="5" Grid.Column="1">
              <CheckBox DockPanel.Dock="Right" Name="DetectCheckVersion" Content="Compare file version" Margin="12,6,0,4"/>
              <TextBox Name="DetectFilePath" FontFamily="Consolas"/>
            </DockPanel>
            <Label Grid.Row="6" Content="MSIX package name"/>
            <TextBox Grid.Row="6" Grid.Column="1" Name="DetectPackageName" FontFamily="Consolas"/>
            <Label Grid.Row="7" Content="Custom script"/>
            <TextBox Grid.Row="7" Grid.Column="1" Name="DetectScript" Style="{StaticResource Code}" Height="120"/>
            <StackPanel Grid.Row="8" Grid.Column="1" Orientation="Horizontal" Margin="0,6,0,2">
              <Button Name="BtnDetectPreview" Content="Preview detection script" Margin="0,3,0,3"/>
              <Button Name="BtnDetectTest" Content="Run preview on this PC"/>
              <TextBlock Name="DetectTestResult" VerticalAlignment="Center" Margin="12,0,0,0" FontWeight="SemiBold"/>
            </StackPanel>
            <TextBox Grid.Row="9" Grid.Column="1" Name="DetectPreview" Style="{StaticResource Code}" IsReadOnly="True" Background="#FAFAFA"/>
          </Grid>
        </TabItem>

        <TabItem Header="  6. Build  ">
          <Grid Margin="12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="170"/>
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
              <ComboBox DockPanel.Dock="Left" Name="OutDeployMode" Width="160" VerticalAlignment="Top"/>
              <TextBlock Style="{StaticResource Hint}" Margin="12,6,0,0" Text="Used in the README install/uninstall command lines. Silent = no dialogs (Required apps); Auto = dialogs when a user is logged on."/>
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
            <StackPanel Grid.Row="5" Grid.Column="1" Orientation="Horizontal" Margin="0,10,0,4">
              <Button Name="BtnGenerate" Content="Generate package" FontWeight="Bold" Padding="18,6" Margin="0,3,0,3"/>
              <Button Name="BtnPreviewScript" Content="Preview deployment script"/>
              <Button Name="BtnOpenOutput" Content="Open output folder"/>
            </StackPanel>
            <TextBlock Grid.Row="6" Grid.Column="1" Style="{StaticResource Hint}" Text="Generate copies sources, creates the PSADT template (downloads the toolkit once if needed), writes the scripts, syntax-checks them and saves Package.json next to the package."/>
            <TextBox Grid.Row="7" Grid.Column="1" Name="OutPreview" Style="{StaticResource Code}" IsReadOnly="True" Background="#FAFAFA"/>
          </Grid>
        </TabItem>

      </TabControl>
      <GridSplitter Grid.Row="1" Height="5" HorizontalAlignment="Stretch" Background="#D0D0D0" Margin="0,4"/>
      <TextBox Grid.Row="2" Name="LogBox" Style="{StaticResource Code}" IsReadOnly="True" Background="#1E1E1E" Foreground="#DDDDDD"/>
    </Grid>
  </DockPanel>
</Window>
'@

$script:Window = [System.Windows.Markup.XamlReader]::Parse($xaml)
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
    $script:ui.StatusText.Text = $Line.Substring(11)
    Invoke-UiRefresh
}

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
    if ($d.ShowDialog($script:Window) -eq $true) { return @($d.FileNames) }
    return @()
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
        if ($info.Type -eq 'EXE' -and $info.Engine -eq 'Unknown')
        {
            Write-PackagerLog 'Installer engine not recognised; enter the silent switches manually.' -Level Warn
        }
    }
    catch
    {
        Write-PackagerLog "Could not read installer: $($_.Exception.Message)" -Level Error
        Show-Message -Text $_.Exception.Message -Title 'Read installer' -Icon Error
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
    $p = Select-FileDialog -Title 'Select the installer' -Filter 'Installers (*.msi;*.exe;*.msix;*.appx;*.msixbundle;*.appxbundle;*.ps1)|*.msi;*.exe;*.msix;*.appx;*.msixbundle;*.appxbundle;*.ps1|All files (*.*)|*.*'
    if ($p.Count -gt 0) { Import-InstallerIntoUi -Path $p[0] }
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
$script:Window.Add_Closing({ Save-PackagerSettings })

# ---- Initial state
Set-UiDefinition -d (New-PackageDefinition)
Read-PackagerSettings
if ($Definition) { Open-DefinitionIntoUi -Path (Resolve-Path -LiteralPath $Definition).Path }
Write-PackagerLog "PSADT Packager $script:PackagerVersion ready (PowerShell $($PSVersionTable.PSVersion))."
$script:Window.ShowDialog() | Out-Null

#endregion
