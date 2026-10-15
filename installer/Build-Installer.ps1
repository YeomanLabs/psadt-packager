<#
.SYNOPSIS
    Builds the PSADT Packager MSI: dist\PSADT-Packager-<version>-x64.msi.

.DESCRIPTION
    1. Reads the version from $script:PackagerVersion in PsadtPackager.ps1.
    2. Draws the icon (installer\obj\PsadtPackager.ico).
    3. Compiles the launcher (Launcher.cs -> "PSADT Packager.exe") with the .NET Framework C# compiler that ships
       with Windows.
    4. Stages the launcher, PsadtPackager.ps1, the icon, README.md, LICENSE and examples\ as the payload.
    5. Builds Package.wxs with WiX 5.0.2 (dotnet build; the SDK comes from NuGet) and copies the MSI to dist\.

    Needs the .NET SDK (any version that can restore WixToolset.Sdk 5.0.2). The MSI is not code-signed.

.EXAMPLE
    .\installer\Build-Installer.ps1
#>
[CmdletBinding()]
param([string]$OutputDir)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$repo = Split-Path -Path $here -Parent
if (-not $OutputDir) { $OutputDir = Join-Path $repo 'dist' }

$scriptPath = Join-Path $repo 'PsadtPackager.ps1'
$m = [regex]::Match([System.IO.File]::ReadAllText($scriptPath), "PackagerVersion\s*=\s*'(\d+\.\d+\.\d+)'")
if (-not $m.Success) { throw 'Could not read $script:PackagerVersion from PsadtPackager.ps1.' }
$version = $m.Groups[1].Value
Write-Host "PSADT Packager $version"

$obj     = Join-Path $here 'obj'
$payload = Join-Path $obj 'payload'
if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Recurse -Force }
New-Item -ItemType Directory -Path $payload -Force | Out-Null

# ---- Icon: a navy tile (YeomanLabs) with a coral arrow dropping into a white box. PNG frames in an .ico.
function New-PackagerIcon
{
    param([Parameter(Mandatory)][string]$Path)
    Add-Type -AssemblyName System.Drawing
    $navy  = [System.Drawing.Color]::FromArgb(255, 4, 22, 53)
    $coral = [System.Drawing.Color]::FromArgb(255, 255, 105, 80)
    $white = [System.Drawing.Color]::White
    $frames = New-Object System.Collections.Generic.List[byte[]]
    $sizes  = @(16, 24, 32, 48, 64, 256)
    foreach ($s in $sizes)
    {
        $k   = $s / 256.0
        $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g   = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)

        # Rounded tile.
        $r = 52 * $k; $x0 = 8 * $k; $x1 = 248 * $k
        $tile = New-Object System.Drawing.Drawing2D.GraphicsPath
        $tile.AddArc($x0, $x0, 2 * $r, 2 * $r, 180, 90)
        $tile.AddArc($x1 - 2 * $r, $x0, 2 * $r, 2 * $r, 270, 90)
        $tile.AddArc($x1 - 2 * $r, $x1 - 2 * $r, 2 * $r, 2 * $r, 0, 90)
        $tile.AddArc($x0, $x1 - 2 * $r, 2 * $r, 2 * $r, 90, 90)
        $tile.CloseFigure()
        $g.FillPath((New-Object System.Drawing.SolidBrush($navy)), $tile)

        # Open box: white U shape with a lid line.
        $w = [Math]::Max(1.6, 18 * $k)
        $pen = New-Object System.Drawing.Pen($white, $w)
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawLines($pen, [System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF((56 * $k), (128 * $k))),
            (New-Object System.Drawing.PointF((56 * $k), (204 * $k))),
            (New-Object System.Drawing.PointF((200 * $k), (204 * $k))),
            (New-Object System.Drawing.PointF((200 * $k), (128 * $k)))))
        $g.DrawLine($pen, (40 * $k), (128 * $k), (92 * $k), (128 * $k))
        $g.DrawLine($pen, (164 * $k), (128 * $k), (216 * $k), (128 * $k))

        # Coral arrow dropping into the box.
        $arrow = New-Object System.Drawing.Drawing2D.GraphicsPath
        $arrow.AddPolygon([System.Drawing.PointF[]]@(
            (New-Object System.Drawing.PointF((110 * $k), (40 * $k))),
            (New-Object System.Drawing.PointF((146 * $k), (40 * $k))),
            (New-Object System.Drawing.PointF((146 * $k), (112 * $k))),
            (New-Object System.Drawing.PointF((178 * $k), (112 * $k))),
            (New-Object System.Drawing.PointF((128 * $k), (168 * $k))),
            (New-Object System.Drawing.PointF((78 * $k), (112 * $k))),
            (New-Object System.Drawing.PointF((110 * $k), (112 * $k)))))
        $g.FillPath((New-Object System.Drawing.SolidBrush($coral)), $arrow)

        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $frames.Add($ms.ToArray())
    }

    # ICO container: header, one directory entry per frame, then the PNG data.
    $out = New-Object System.IO.MemoryStream
    $bw  = New-Object System.IO.BinaryWriter($out)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++)
    {
        $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$frames[$i].Length); $bw.Write([uint32]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($f in $frames) { $bw.Write($f) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $out.ToArray())
}

$icon = Join-Path $obj 'PsadtPackager.ico'
New-PackagerIcon -Path $icon
Write-Host "Icon: $icon"

# ---- Launcher
$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { throw "The .NET Framework C# compiler was not found at $csc." }
$source = Join-Path $obj 'Launcher.cs'
[System.IO.File]::WriteAllText($source, ([System.IO.File]::ReadAllText((Join-Path $here 'Launcher.cs')).Replace('__VERSION__', $version)))
$exe = Join-Path $payload 'PSADT Packager.exe'
$cscOut = & $csc /nologo /target:winexe /platform:anycpu /optimize+ "/win32icon:$icon" "/out:$exe" /reference:System.Windows.Forms.dll $source 2>&1
if ($LASTEXITCODE -ne 0) { throw "Launcher did not compile:`n$($cscOut -join "`n")" }
Write-Host "Launcher: $exe"

# ---- Payload
Copy-Item -LiteralPath $scriptPath -Destination $payload
Copy-Item -LiteralPath (Join-Path $repo 'README.md') -Destination $payload
Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination $payload
Copy-Item -LiteralPath $icon -Destination $payload
Copy-Item -LiteralPath (Join-Path $repo 'examples') -Destination $payload -Recurse

# ---- MSI
$wixproj = Join-Path $here 'PsadtPackager.Installer.wixproj'
$build = & dotnet build $wixproj -c Release -nologo "-p:Version=$version" "-p:PayloadDir=$payload\" "-p:IconPath=$icon" 2>&1
if ($LASTEXITCODE -ne 0) { throw "WiX build failed:`n$($build -join "`n")" }
$msi = Get-ChildItem -LiteralPath (Join-Path $here 'bin') -Recurse -Filter 'PSADT-Packager.msi' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $msi) { throw "The WiX build reported success but no MSI was found under $here\bin." }
if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$final = Join-Path $OutputDir "PSADT-Packager-$version-x64.msi"
Copy-Item -LiteralPath $msi.FullName -Destination $final -Force

# ---- Check what was built
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @([string]$final, 0))   # [string]: COM rejects the PSObject wrapper Join-Path output carries
$props = @{}
foreach ($name in 'ProductName', 'ProductVersion', 'ProductCode', 'Manufacturer', 'UpgradeCode')
{
    $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property = '$name'"))
    [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
    $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    if ($rec) { $props[$name] = $rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1)) }
    [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
}
$fileView = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @('SELECT FileName FROM File'))
[void]$fileView.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $fileView, $null)
$files = @()
while ($true)
{
    $rec = $fileView.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $fileView, $null)
    if (-not $rec) { break }
    $files += (($rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1))) -split '\|')[-1]
}
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer)
if ($props['ProductVersion'] -ne $version) { throw "MSI ProductVersion is '$($props['ProductVersion'])', expected $version." }
foreach ($required in 'PSADT Packager.exe', 'PsadtPackager.ps1') { if ($files -notcontains $required) { throw "MSI is missing $required." } }

Write-Host ''
Write-Host "Built $final ($([Math]::Round((Get-Item -LiteralPath $final).Length / 1KB)) KB)"
Write-Host "  $($props['ProductName']) $($props['ProductVersion']) by $($props['Manufacturer'])"
Write-Host "  ProductCode $($props['ProductCode'])  UpgradeCode $($props['UpgradeCode'])"
Write-Host "  Files: $($files -join ', ')"
$final
