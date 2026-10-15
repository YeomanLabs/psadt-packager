<#
.SYNOPSIS
    Offline regression tests for PsadtPackager.ps1 - no sandbox, no network, no tenant.

.DESCRIPTION
    Loads the packager's functions without starting the GUI or a build, then checks the pure logic: name / version /
    vendor clean-up, input classification (folders, zips, scripts, portable apps), command-line quoting, how a sandbox
    result turns into detection and uninstall settings, and that every generated script parses for every install,
    uninstall and detection type. Runs on Windows PowerShell 5.1 and PowerShell 7. Exit code = number of failures.

.EXAMPLE
    .\tests\Test-PsadtPackager.ps1
#>
[CmdletBinding()]
param([string]$ScriptPath)

$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 has no $PSScriptRoot in parameter defaults, so resolve it here.
if (-not $ScriptPath) { $ScriptPath = Join-Path (Split-Path -Path $MyInvocation.MyCommand.Path -Parent) '..\PsadtPackager.ps1' }
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

# Load every function and script variable that precedes the headless entry point.
$ast  = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
$text = [System.IO.File]::ReadAllText($ScriptPath)
$cut  = $text.IndexOf('#region ---------------------------------------------------------------- Headless entry point')
if ($cut -lt 0) { throw 'Headless entry point marker not found in PsadtPackager.ps1.' }
. ([scriptblock]::Create((($ast.EndBlock.Statements | Where-Object { $_.Extent.EndOffset -le $cut } | ForEach-Object { $_.Extent.Text }) -join "`n`n")))
$script:LogSink = { param($Line, $Level) }

$script:Failures = 0
$script:Passes   = 0
function Assert-Equal($Actual, $Expected, [string]$Name)
{
    if ("$Actual" -ceq "$Expected") { $script:Passes++ }
    else { $script:Failures++; Write-Host "FAIL  $Name`n      expected [$Expected]`n      actual   [$Actual]" -ForegroundColor Red }
}
function Assert-True($Condition, [string]$Name)
{
    if ($Condition) { $script:Passes++ } else { $script:Failures++; Write-Host "FAIL  $Name" -ForegroundColor Red }
}
function Assert-Parses([string]$Code, [string]$Name)
{
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$errors)
    if (@($errors).Count -eq 0) { $script:Passes++ }
    else { $script:Failures++; Write-Host "FAIL  $Name does not parse: $(@($errors)[0].Message) (line $(@($errors)[0].Extent.StartLineNumber))" -ForegroundColor Red }
}

# ---- Names, versions, vendors
Assert-Equal (Get-CleanAppName -Name '7-Zip 26.04 (x64 edition)' -Version '26.04.00.0') '7-Zip' 'clean name: 7-Zip'
Assert-Equal (Get-CleanAppName -Name 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.44.35211' -Version '14.44.35211.0') 'Microsoft Visual C++ 2015-2022 Redistributable' 'clean name: VC++ redist'
Assert-Equal (Get-CleanAppName -Name 'Notepad++ (64-bit x64)' -Version '8.9.8.1') 'Notepad++' 'clean name: Notepad++'
Assert-Equal (Get-CleanAppName -Name 'Node.js') 'Node.js' 'clean name: keeps dots in names'
Assert-Equal (Get-CleanAppName -Name 'Contoso(R) Widget' ) 'Contoso Widget' 'clean name: (R) removed'
Assert-Equal (Get-CleanAppName -Name ('Microsoft' + [char]0x00AE + ' Windows' + [char]0x00AE + ' Tool' + [char]0x2122)) 'Microsoft Windows Tool' 'clean name: trademark symbols removed'
Assert-Equal (Get-CleanAppName -Name ('Pr' + [char]0x00E2 + 'ce Viewer')) ('Pr' + [char]0x00E2 + 'ce Viewer') 'clean name: accented letters kept'
# Windows PowerShell 5.1 reads a file without a BOM as ANSI, so the script must stay pure ASCII.
Assert-True (-not ([System.IO.File]::ReadAllText($ScriptPath) -match '[^\x00-\x7F]')) 'PsadtPackager.ps1 is pure ASCII'

# ---- Scripts that only ever run inside Windows Sandbox: a mistake there would only show up in a sandbox run.
Assert-Parses $script:SandboxProbeScript 'sandbox probe script (Run-Probe.ps1)'
Assert-Parses $script:ClassicSandboxBootstrap 'classic sandbox logon script (Start-Classic.ps1)'
$probeCs = [regex]::Match($script:SandboxProbeScript, '(?s)Add-Type -TypeDefinition @"\r?\n(.*?)\r?\n"@')
Assert-True $probeCs.Success 'probe script carries its C# helper'
$compiled = $true
try { Add-Type -TypeDefinition $probeCs.Groups[1].Value -ErrorAction Stop } catch { $compiled = $false; Write-Host "    $($_.Exception.Message)" }
Assert-True $compiled 'probe C# helper compiles'
if ($compiled)
{
    $since = (Get-Date).ToUniversalTime()
    $fdir = Join-Path ([System.IO.Path]::GetTempPath()) ('psadt-newfiles-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path "$fdir\App\bin", "$fdir\Skip\x" -Force | Out-Null
    'a' | Set-Content "$fdir\App\bin\new.dll"; 'b' | Set-Content "$fdir\Skip\x\noise.log"
    $nf = "$([ProbeWin]::NewFilesSince([string[]]@($fdir), [string[]]@("$fdir\Skip\"), $since.AddSeconds(-1), 2000))".Split('|')
    Assert-Equal "$($nf[0])|$(Split-Path $nf[1] -Leaf)|$($nf[2])" '1|new.dll|' 'progress: counts new files, skips the noisy folder'
    Remove-Item -LiteralPath $fdir -Recurse -Force -ErrorAction SilentlyContinue
}
$split = Split-NameAndVersion 'Contoso Agent 2.1.0'; Assert-Equal "$($split.Name)|$($split.Version)" 'Contoso Agent|2.1.0' 'split: spaces'
$split = Split-NameAndVersion 'contoso_agent_v2.1';  Assert-Equal "$($split.Name)|$($split.Version)" 'contoso agent|2.1' 'split: underscores and v'
$split = Split-NameAndVersion 'npp.8.9.8.1.Installer.x64'; Assert-Equal "$($split.Name)|$($split.Version)" 'npp|8.9.8.1' 'split: dotted file name'
$split = Split-NameAndVersion 'DemoTool'; Assert-Equal "$($split.Name)|$($split.Version)" 'DemoTool|' 'split: no version'
Assert-Equal (Get-CleanVendor -Text 'Don HO don.h@free.fr') 'Don HO' 'vendor: e-mail removed'
Assert-Equal (Get-CleanVendor -Text 'https://winmerge.org') '' 'vendor: URL dropped'
Assert-Equal (Get-CleanVendor -Text 'Contoso <support@contoso.com>') 'Contoso' 'vendor: <e-mail> removed'
$vi = [pscustomobject]@{ ProductVersion = '8.981'; FileVersion = '8.9.8.1'; ProductMajorPart = 8; ProductMinorPart = 9; ProductBuildPart = 8; ProductPrivatePart = 1; FileMajorPart = 8; FileMinorPart = 9; FileBuildPart = 8; FilePrivatePart = 1 }
Assert-Equal (Get-FileVersionText $vi) '8.9.8.1' 'version: numeric fields win over a mangled text version'
$vi = [pscustomobject]@{ ProductVersion = '14.44.35211.0'; FileVersion = ''; ProductMajorPart = 14; ProductMinorPart = 44; ProductBuildPart = 35211; ProductPrivatePart = 0; FileMajorPart = 0; FileMinorPart = 0; FileBuildPart = 0; FilePrivatePart = 0 }
Assert-Equal (Get-FileVersionText $vi) '14.44.35211.0' 'version: text kept when it agrees'
Assert-Equal (Get-ArchFromText 'npp.8.9.8.1.Installer.x64.exe') 'x64' 'arch: x64 from file name'
Assert-Equal (Get-ArchFromText 'tool-arm64.msi') 'ARM64' 'arch: arm64 from file name'
Assert-Equal (Get-ArchFromText 'setup.exe') '' 'arch: none'
Assert-Equal (Get-VersionedNamePattern -DisplayName 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - 14.44.35211' -Version '14.44.35211.0') 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - *' 'pattern: version replaced'
Assert-Equal (Get-VersionedNamePattern -DisplayName 'Notepad++ (64-bit x64)' -Version '8.9.8.1') '' 'pattern: none when the name has no version'
Assert-Equal (Get-VersionedNamePattern -DisplayName 'App [Beta] 2.0' -Version '2.0') 'App `[Beta`] *' 'pattern: wildcard characters escaped'
Assert-Equal (ConvertTo-PortablePath 'C:\Program Files (x86)\App\app.exe') '${env:ProgramFiles(x86)}\App\app.exe' 'portable path: x86'
Assert-Equal (ConvertTo-PortablePath 'C:\Program Files\App') '$env:ProgramFiles\App' 'portable path: Program Files'
Assert-Equal (ConvertTo-PortablePath 'C:\ProgramData\Package Cache\{x}\a.exe') '$env:ProgramData\Package Cache\{x}\a.exe' 'portable path: ProgramData'
Assert-Equal (ConvertTo-CommandLineArgument 'plain') 'plain' 'quote: plain'
Assert-Equal (ConvertTo-CommandLineArgument 'has space') '"has space"' 'quote: space'
Assert-Equal (ConvertTo-CommandLineArgument 'say "hi"') '"say \"hi\""' 'quote: inner quotes'
Assert-Equal (ConvertTo-CommandLineArgument 'C:\dir with space\') '"C:\dir with space\\"' 'quote: trailing backslash'
Assert-Equal (ConvertTo-CommandLineArgument '') '""' 'quote: empty'

# ---- Input classification (synthetic folders; the "program" is a copy of a Windows console tool)
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('psadt-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try
{
    $tool = Join-Path $env:SystemRoot 'System32\where.exe'
    $d = New-Item -ItemType Directory -Path (Join-Path $tmp 'Contoso Widget 2.1')
    Set-Content -Path (Join-Path $d 'install.cmd') -Value '@exit /b 0'
    Set-Content -Path (Join-Path $d 'uninstall.cmd') -Value '@exit /b 0'
    Copy-Item $tool (Join-Path $d 'widget.exe')
    $r = Resolve-PackageInput -Path $d.FullName
    Assert-Equal "$($r.Kind)|$($r.EntryRelative)|$($r.UninstallScript)|$($r.NameHint)" 'Script|install.cmd|uninstall.cmd|Contoso Widget 2.1' 'input: folder with install/uninstall scripts'
    $r = Resolve-PackageInput -Path (Join-Path $d 'install.cmd')
    Assert-Equal "$($r.Kind)|$($r.IsFolder)|$($r.EntryRelative)|$($r.UninstallScript)|$($r.NameHint)" 'Script|True|install.cmd|uninstall.cmd|Contoso Widget 2.1' 'input: a generic install script brings its folder'

    $d = New-Item -ItemType Directory -Path (Join-Path $tmp 'msi')
    Set-Content -Path (Join-Path $d 'product.msi') -Value 'x'
    Set-Content -Path (Join-Path $d 'company.mst') -Value 'x'
    $r = Resolve-PackageInput -Path $d.FullName
    Assert-Equal "$($r.Kind)|$($r.EntryRelative)|$(@($r.Transforms) -join ',')" 'MSI|product.msi|company.mst' 'input: single MSI with a transform'

    $d = New-Item -ItemType Directory -Path (Join-Path $tmp 'wrapper\Inner App 3.0') -Force
    Set-Content -Path (Join-Path $d 'setup.cmd') -Value '@exit /b 0'
    $r = Resolve-PackageInput -Path (Join-Path $tmp 'wrapper')
    Assert-Equal "$($r.Kind)|$($r.EntryRelative)" 'Script|setup.cmd' 'input: wrapper folder is unwrapped'

    $src = New-Item -ItemType Directory -Path (Join-Path $tmp 'zipsrc\DemoTool') -Force
    Copy-Item $tool (Join-Path $src 'DemoTool.exe')
    Copy-Item $tool (Join-Path $src 'uninstall.exe')
    Set-Content -Path (Join-Path $src 'readme.txt') -Value 'x'
    $zip = Join-Path $tmp 'DemoTool-1.4.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $tmp 'zipsrc'), $zip)
    $r = Resolve-PackageInput -Path $zip
    Assert-Equal "$($r.Kind)|$($r.EntryRelative)|$($r.NameHint)" 'Portable|DemoTool.exe|DemoTool-1.4' 'input: zipped portable app, uninstaller skipped'
    $def = Set-DefinitionForPortable -Def (New-PackageDefinition) -PackageInput $r
    Assert-Equal "$($def.App.Name)|$($def.App.Version)|$($def.Install.Type)|$($def.Detection.Type)" 'DemoTool|1.4|Custom|File' 'portable: unrelated product name falls back to the zip name'
    Assert-True ($def.Detection.FilePath -eq '$env:ProgramFiles\DemoTool\DemoTool.exe') 'portable: detection path'
    Assert-True ($def.Detection.MinVersion -eq ('{0}.{1}.{2}.{3}' -f (Get-Item $tool).VersionInfo.FileMajorPart, (Get-Item $tool).VersionInfo.FileMinorPart, (Get-Item $tool).VersionInfo.FileBuildPart, (Get-Item $tool).VersionInfo.FilePrivatePart)) 'portable: detection uses the real file version'
    if (Test-Path -LiteralPath $r.Root) { Remove-Item -LiteralPath (Split-Path -Path $r.Root -Parent) -Recurse -Force -ErrorAction SilentlyContinue }

    $f = New-Item -ItemType File -Path (Join-Path $tmp 'Northwind Notes 1.2.vbs')
    $r = Resolve-PackageInput -Path $f.FullName
    Assert-Equal "$($r.Kind)|$($r.IsFolder)|$($r.NameHint)" 'Script|False|Northwind Notes 1.2' 'input: single script file'
    $info = Get-InstallerInfo -Path $f.FullName
    Assert-Equal "$($info.Type)|$($info.Name)|$($info.Version)" 'Script|Northwind Notes|1.2' 'info: script name and version from file name'
}
finally
{
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- Sandbox result -> definition
$entry = [pscustomobject]@{ Id = 'LocalMachine\Registry64\X'; KeyName = 'X'; Location = 'LocalMachine\Registry64'; DisplayName = 'Contoso App (x64) - 2.1.0'; DisplayVersion = '2.1.0'; Publisher = 'Contoso Ltd'; UninstallString = '"C:\Program Files\Contoso\unins000.exe"'; QuietUninstallString = ''; InstallLocation = 'C:\Program Files\Contoso'; SystemComponent = 0 }
$fp = [pscustomobject]@{ Folders = @([pscustomobject]@{ Path = 'C:\Program Files\Contoso'; PerUser = $false; Exes = @([pscustomobject]@{ Path = 'C:\Program Files\Contoso\unins000.exe'; FileVersion = '1.0.0.0'; Size = 1 }, [pscustomobject]@{ Path = 'C:\Program Files\Contoso\ContosoApp.exe'; FileVersion = '2.1.0.5'; Size = 9 }) }); Shortcuts = @(); RegistryKeys = @(); Services = @(); Tasks = @(); PerUser = @() }
$probe = [pscustomobject]@{ InstallSucceeded = $true; Candidate = '/VERYSILENT'; PrimaryEntry = $entry; NewEntries = @($entry); Footprint = $fp; Uninstall = [pscustomobject]@{ Verified = $true; File = 'C:\Program Files\Contoso\unins000.exe'; Arguments = '/VERYSILENT' } }
$def = New-PackageDefinition; $def.Install.Type = 'EXE'; $def.App.Name = 'Contoso App'; $def.App.Vendor = 'contoso.com'
[void](Set-DefinitionFromProbe -Def $def -Result $probe -Auto)
Assert-Equal "$($def.Install.Arguments)|$($def.App.Vendor)|$($def.App.Version)|$($def.App.Arch)" '/VERYSILENT|Contoso Ltd|2.1.0|x64' 'probe: install args and registered metadata'
Assert-Equal "$($def.Detection.Type)|$($def.Detection.MatchMode)|$($def.Detection.DisplayName)|$($def.Detection.MinVersion)" 'Registry|Wildcard|Contoso App (x64) - *|2.1.0' 'probe: version-tolerant registry detection'
Assert-Equal "$($def.Uninstall.Type)|$($def.Uninstall.Name)|$($def.Uninstall.ApplicationType)|$($def.Uninstall.Arguments)" 'Name|Contoso App (x64) - *|EXE|/VERYSILENT' 'probe: verified uninstall runs by name with the proven arguments'
Assert-Equal $def.App.Name 'Contoso App' 'probe: name comes from the registered DisplayName'
$brave = [pscustomobject]@{ Id = 'LocalMachine\Registry32\BraveSoftware Brave-Browser'; KeyName = 'BraveSoftware Brave-Browser'; Location = 'LocalMachine\Registry32'; DisplayName = 'Brave'; DisplayVersion = '155.1.97.57'; Publisher = 'Brave Software Inc'; UninstallString = '"C:\Program Files\BraveSoftware\Brave-Browser\Application\155.1.97.57\Installer\setup.exe" --uninstall --system-level'; QuietUninstallString = ''; InstallLocation = ''; SystemComponent = 0 }
$braveFp = [pscustomobject]@{ Folders = @([pscustomobject]@{ Path = 'C:\Program Files\BraveSoftware'; PerUser = $false; Exes = @([pscustomobject]@{ Path = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe'; Machine = 'x64'; FileVersion = '155.1.97.57'; Size = 9 }) }); Shortcuts = @([pscustomobject]@{ Path = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Brave.lnk'; Target = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe' }); RegistryKeys = @(); Services = @(); Tasks = @(); PerUser = @() }
$braveProbe = [pscustomobject]@{ InstallSucceeded = $true; Candidate = '/silent /install'; PrimaryEntry = $brave; NewEntries = @($brave); Footprint = $braveFp; Uninstall = [pscustomobject]@{ Verified = $true; ExitCode = 19; File = 'C:\Program Files\BraveSoftware\Brave-Browser\Application\155.1.97.57\Installer\setup.exe'; Arguments = '--uninstall --system-level --force-uninstall' } }
$bdef = New-PackageDefinition; $bdef.Install.Type = 'EXE'; $bdef.App.Name = 'BraveSoftware Update'
[void](Set-DefinitionFromProbe -Def $bdef -Result $braveProbe -Auto)
Assert-Equal "$($bdef.App.Name)|$($bdef.App.Arch)|$(@($bdef.Uninstall.SuccessExitCodes) -join ',')" 'Brave|x64|19' 'probe: Omaha app named from its entry, arch from brave.exe, exit 19 accepted'
$bcode = (New-UninstallActionCode -Def $bdef) -join "`n"
Assert-True ($bcode -match [regex]::Escape("Get-ADTApplication -Name 'Brave' -NameMatch Exact -ApplicationType EXE")) 'codegen: name uninstall matches the exact DisplayName, not every name containing it'
Assert-True ($bcode -match [regex]::Escape('Start-ADTProcess @sapParams -IgnoreExitCodes @(19)')) 'codegen: the proven exit code is ignored, so the package itself exits 0 for Intune'
# Run the generated block against stand-ins for the toolkit: the registered uninstaller, the proven arguments, a neutral working
# directory (Chromium's setup.exe returns 20 when started from the version folder it deletes), every match, nothing when none.
$script:calls = New-Object System.Collections.Generic.List[object]
$script:fakeApps = @([pscustomobject]@{ DisplayName = 'Brave'; DisplayVersion = '155.1.97.57'; UninstallStringFilePath = 'C:\B\setup.exe'; UninstallStringArgumentList = @('--uninstall', '--system-level'); QuietUninstallStringFilePath = $null; QuietUninstallStringArgumentList = $null })
function Get-ADTApplication { param($Name, $NameMatch, $ApplicationType) $script:calls.Add("get|$Name|$NameMatch|$ApplicationType"); $script:fakeApps }
function Start-ADTProcess { param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, $IgnoreExitCodes) $script:calls.Add("run|$FilePath|$($ArgumentList -join ' ')|$WorkingDirectory|$WindowStyle|$($IgnoreExitCodes -join ',')") }
function Write-ADTLogEntry { param($Message, $Severity) $script:calls.Add("log|$Severity") }
& ([scriptblock]::Create($bcode))
Assert-Equal ($script:calls -join ' ; ') "get|Brave|Exact|EXE ; log| ; run|C:\B\setup.exe|--uninstall --system-level --force-uninstall|$env:SystemRoot|Hidden|19" 'codegen run: proven arguments, neutral working directory, exit 19 ignored'
$script:calls.Clear(); $bdef.Uninstall.Arguments = ''
$script:fakeApps += [pscustomobject]@{ DisplayName = 'Brave'; DisplayVersion = '1'; UninstallStringFilePath = 'C:\B\u.exe'; UninstallStringArgumentList = @('/x'); QuietUninstallStringFilePath = 'C:\B\q.exe'; QuietUninstallStringArgumentList = @('/quiet', '/norestart') }
& ([scriptblock]::Create(((New-UninstallActionCode -Def $bdef) -join "`n")))
Assert-Equal (@($script:calls | Where-Object { $_ -like 'run|*' }) -join ' ; ') "run|C:\B\setup.exe|--uninstall --system-level|$env:SystemRoot|Hidden|19 ; run|C:\B\q.exe|/quiet /norestart|$env:SystemRoot|Hidden|19" 'codegen run: no proven arguments uses the registered command, quiet one first, for every match'
$script:calls.Clear(); $script:fakeApps = @()
& ([scriptblock]::Create(((New-UninstallActionCode -Def $bdef) -join "`n")))
Assert-Equal ($script:calls -join ' ; ') 'get|Brave|Exact|EXE ; log|2' 'codegen run: nothing installed logs a warning and runs nothing'
Remove-Item Function:\Get-ADTApplication, Function:\Start-ADTProcess, Function:\Write-ADTLogEntry
$ndef = New-PackageDefinition; $ndef.Uninstall.Type = 'Name'; $ndef.Uninstall.ApplicationType = 'All'
$ndef.Uninstall.Name = 'Contoso App (x64) - *'
Assert-True ((New-UninstallActionCode -Def $ndef) -join "`n" -match [regex]::Escape("Uninstall-ADTApplication -Name 'Contoso App (x64) - *' -NameMatch Wildcard")) 'codegen: wildcard name matches as a wildcard'
$ndef.Uninstall.Name = '^Contoso App \d'; $ndef.Uninstall.NameIsRegex = $true
Assert-True ((New-UninstallActionCode -Def $ndef) -join "`n" -match [regex]::Escape("Uninstall-ADTApplication -Name '^Contoso App \d' -NameMatch Regex")) 'codegen: regex name is passed as the name, matched as regex'
$ndef.Uninstall.SuccessExitCodes = @(3010, 0)
Assert-True (-not ((New-UninstallActionCode -Def $ndef) -join "`n" -match 'IgnoreExitCodes')) 'codegen: success and reboot codes are never ignored'

$probeNoEntry =[pscustomobject]@{ InstallSucceeded = $true; Candidate = '/S'; PrimaryEntry = $null; NewEntries = @(); Footprint = $null; Uninstall = [pscustomobject]@{ Verified = $true; File = 'C:\Program Files (x86)\Tool\remove.exe'; Arguments = '/S' } }
$def2 = New-PackageDefinition; $def2.Install.Type = 'EXE'
[void](Set-DefinitionFromProbe -Def $def2 -Result $probeNoEntry -Auto)
Assert-Equal "$($def2.Uninstall.Type)|$($def2.Uninstall.File)" 'EXE|${env:ProgramFiles(x86)}\Tool\remove.exe' 'probe: verified uninstall without an entry keeps the portable path'
Assert-Equal (@($def.Install.ProcessesToClose) -join ',') 'ContosoApp' 'probe: main program becomes a process to close'

$fp2 = [pscustomobject]@{ Folders = @([pscustomobject]@{ Path = 'C:\Program Files\Widget'; PerUser = $false; Exes = @([pscustomobject]@{ Path = 'C:\Program Files\Widget\widget.exe'; FileVersion = '10.0.1.0'; Size = 1 }) }); Shortcuts = @(); RegistryKeys = @('HKLM\SOFTWARE\Contoso\Widget'); Services = @([pscustomobject]@{ Name = 'WidgetSvc'; DisplayName = 'Widget'; PathName = 'x' }); Tasks = @('\Contoso\Widget Update'); PerUser = @() }
$probe2 = [pscustomobject]@{ InstallSucceeded = $true; Candidate = ''; PrimaryEntry = $null; NewEntries = @(); Footprint = $fp2; Uninstall = $null }
$def = New-PackageDefinition; $def.Install.Type = 'Script'; $def.Install.File = 'install.cmd'; $def.App.Name = 'Contoso Widget'; $def.App.Version = '2.1'
[void](Set-DefinitionFromProbe -Def $def -Result $probe2 -Auto)
Assert-Equal "$($def.Detection.Type)|$($def.Detection.FilePath)|$($def.Detection.MinVersion)" 'File|$env:ProgramFiles\Widget\widget.exe|10.0.1.0' 'probe: footprint-only install detects the program file'
Assert-Equal $def.Uninstall.Type 'Custom' 'probe: footprint-only install gets generated clean-up'
Assert-True ($def.Uninstall.CustomScript -match 'WidgetSvc' -and $def.Uninstall.CustomScript -match 'Widget Update' -and $def.Uninstall.CustomScript -match 'HKLM:\\SOFTWARE\\Contoso\\Widget') 'probe: clean-up covers service, task and key'
Assert-Parses $def.Uninstall.CustomScript 'generated clean-up'

$fp3 = [pscustomobject]@{ Folders = @([pscustomobject]@{ Path = 'C:\Program Files\Northwind Notes'; PerUser = $false; Exes = @() }); Shortcuts = @(); RegistryKeys = @(); Services = @(); Tasks = @(); PerUser = @() }
$probe3 = [pscustomobject]@{ InstallSucceeded = $true; Candidate = ''; PrimaryEntry = $null; NewEntries = @(); Footprint = $fp3; Uninstall = $null }
$def = New-PackageDefinition; $def.Install.Type = 'Script'; $def.Install.File = 'setup.vbs'; $def.Detection.Type = 'Script'; $def.Detection.Script = ''
[void](Set-DefinitionFromProbe -Def $def -Result $probe3 -Auto)
Assert-True ($def.Detection.Type -eq 'Script' -and $def.Detection.Script -match [regex]::Escape('$env:ProgramFiles\Northwind Notes')) 'probe: folder-only install detects the folder'
Assert-Parses (New-DetectionScript -Def $def) 'folder detection script'

$def = New-PackageDefinition; $def.Install.Type = 'Script'; $def.Install.File = 'Install.ps1'; $def.Uninstall.Type = 'Script'; $def.Uninstall.File = 'Uninstall.ps1'
[void](Set-DefinitionFromProbe -Def $def -Result $probe -Auto)
Assert-Equal "$($def.Uninstall.Type)|$($def.Uninstall.File)" 'Script|Uninstall.ps1' 'probe: a shipped uninstall script is kept'

# ---- Every generated script parses
$base = New-PackageDefinition
$base.App.Name = "O'Brien App"; $base.App.Vendor = 'Contoso'; $base.App.Version = '1.0'
$installs = @(
    @{ Type = 'MSI'; File = 'app.msi'; Arguments = 'ALLUSERS=1'; Transforms = @('a.mst') },
    @{ Type = 'EXE'; File = 'setup.exe'; Arguments = '/S /D="C:\Program Files\App"' },
    @{ Type = 'Script'; File = 'sub\Install.ps1'; Arguments = '-Mode Silent' },
    @{ Type = 'Script'; File = 'install.cmd'; Arguments = 'quiet "x y"' },
    @{ Type = 'Script'; File = 'install.bat'; Arguments = '' },
    @{ Type = 'Script'; File = 'setup.vbs'; Arguments = '/q' },
    @{ Type = 'MSIX'; File = 'app.msix'; Arguments = '' },
    @{ Type = 'Custom'; File = ''; CustomScript = 'Write-ADTLogEntry -Message ''custom''' }
)
$uninstalls = @(
    @{ Type = 'MSI'; ProductCode = '{11111111-2222-3333-4444-555555555555}' },
    @{ Type = 'Name'; Name = 'App (x64) - *' },
    @{ Type = 'Name'; Name = 'App'; Arguments = '/S' },
    @{ Type = 'Name'; Name = "O'Brien App"; ApplicationType = 'EXE'; Arguments = '--uninstall --force-uninstall'; SuccessExitCodes = @(19) },
    @{ Type = 'Name'; Name = '^App \d'; NameIsRegex = $true; ApplicationType = 'EXE' },
    @{ Type = 'EXE'; File = '${env:ProgramFiles(x86)}\App\unins000.exe'; Arguments = '/VERYSILENT' },
    @{ Type = 'Script'; File = 'uninstall.cmd' },
    @{ Type = 'Script'; File = 'Uninstall.ps1' },
    @{ Type = 'MSIX'; PackageName = 'Contoso.App' },
    @{ Type = 'Custom'; CustomScript = (New-FootprintUninstallCode -Footprint $fp2) },
    @{ Type = 'None' }
)
$detections = @(
    @{ Type = 'MSI'; ProductCode = '{11111111-2222-3333-4444-555555555555}'; MinVersion = '1.0' },
    @{ Type = 'Registry'; DisplayName = "O'Brien App*"; MatchMode = 'Wildcard'; MinVersion = '1.0' },
    @{ Type = 'File'; FilePath = '${env:ProgramFiles(x86)}\App\app.exe'; MinVersion = '1.0'; CheckFileVersion = $true },
    @{ Type = 'MSIX'; PackageName = 'Contoso.App' },
    @{ Type = 'Script'; Script = "if (Test-Path 'HKLM:\SOFTWARE\X') { 'Detected'; exit 0 }`r`nexit 1" }
)
$n = 0
foreach ($i in $installs)
{
    foreach ($u in $uninstalls)
    {
        $def = New-PackageDefinition
        $def.App.Name = $base.App.Name; $def.App.Vendor = $base.App.Vendor; $def.App.Version = $base.App.Version
        $def.Install.ProcessesToClose = @('app', "word|Microsoft Word")
        foreach ($k in $i.Keys) { $def.Install.$k = $i[$k] }
        foreach ($k in $u.Keys) { $def.Uninstall.$k = $u[$k] }
        Assert-Parses (New-DeploymentSections -Def $def) "deployment script ($($i.Type) $($i.File) / uninstall $($u.Type))"
        $n++
    }
}
foreach ($d in $detections)
{
    $def = New-PackageDefinition
    $def.App.Name = $base.App.Name
    foreach ($k in $d.Keys) { $def.Detection.$k = $d[$k] }
    Assert-Parses (New-DetectionScript -Def $def) "detection script ($($d.Type))"
}

# ---- Definition validation returns a usable list
$def = New-PackageDefinition
$def.App.Name = 'App'; $def.App.Version = '1.0'; $def.Output.Destination = 'C:\Packages'
$def.Install.Type = 'Custom'; $def.Install.CustomScript = 'x'; $def.Uninstall.Type = 'None'; $def.Detection.Type = 'Script'; $def.Detection.Script = 'exit 1'
$problems = Test-PackageDefinition -Def $def
Assert-Equal $problems.Count 0 'validation: complete definition has no problems'

$colour = if ($script:Failures) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed (PowerShell {2})" -f $script:Passes, $script:Failures, $PSVersionTable.PSVersion) -ForegroundColor $colour
exit $script:Failures
