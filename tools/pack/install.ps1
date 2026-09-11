# goo-4k installer: patches the stock World of Goo exe and SDL2.dll in place, installs the
# presentation shim, the 4x font entries in resources.xml, optional 4x textures, and sets the
# framebuffer/vsync config lines.
# Run via install.cmd. Usage: install.ps1 [-GameDir <path>] [-Uninstall] [-NoTextures]
param(
    [string]$GameDir = "",
    [switch]$Uninstall,
    [switch]$NoTextures
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-GameDir {
    if ($GameDir -and (Test-Path (Join-Path $GameDir 'Win64\WorldOfGoo.exe'))) { return (Resolve-Path $GameDir).Path }
    $candidates = @("${env:ProgramFiles(x86)}\Steam\steamapps\common\World of Goo", "$env:ProgramFiles\Steam\steamapps\common\World of Goo")
    $vdf = "${env:ProgramFiles(x86)}\Steam\steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $candidates += ($m.Groups[1].Value -replace '\\\\', '\') + '\steamapps\common\World of Goo'
        }
    }
    foreach ($c in $candidates) { if (Test-Path (Join-Path $c 'Win64\WorldOfGoo.exe')) { return $c } }
    throw "World of Goo not found. Pass -GameDir <folder containing Win64 and game>."
}

function Sha256([string]$path) { (Get-FileHash -Algorithm SHA256 $path).Hash.ToLower() }
function HexToBytes([string]$hex) { $b = New-Object byte[] ($hex.Length / 2); for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($hex.Substring(2 * $i, 2), 16) }; return ,$b }

function Apply-Manifest([string]$manifestPath, [string]$target, [string]$backupDir) {
    $m = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $cur = Sha256 $target
    if ($cur -eq $m.patched_sha256) { Write-Host "  $($m.name): already patched"; return }
    if ($cur -ne $m.stock_sha256) { throw "$($m.name): unexpected file (sha256 $cur). This patcher is for the Steam build the mod was made against. Verify game files in Steam and retry." }
    $data = [IO.File]::ReadAllBytes($target)
    foreach ($p in $m.patches) {
        $old = HexToBytes $p.old
        for ($i = 0; $i -lt $old.Length; $i++) { if ($data[$p.off + $i] -ne $old[$i]) { throw "$($m.name): byte mismatch at offset $($p.off)" } }
        $new = HexToBytes $p.new
        [Array]::Copy($new, 0, $data, $p.off, $new.Length)
    }
    $out = New-Object byte[] ($m.patched_size)
    [Array]::Copy($data, 0, $out, 0, $data.Length)
    if ($m.append.Length -gt 0) { $tail = HexToBytes $m.append; [Array]::Copy($tail, 0, $out, $data.Length, $tail.Length) }
    New-Item -ItemType Directory -Force $backupDir | Out-Null
    Copy-Item $target (Join-Path $backupDir (Split-Path -Leaf $target)) -Force
    [IO.File]::WriteAllBytes($target, $out)
    if ((Sha256 $target) -ne $m.patched_sha256) { throw "$($m.name): result hash mismatch" }
    Write-Host "  $($m.name): patched ($($m.patches.Count) runs, $($m.append.Length / 2) bytes appended)"
}

function Set-ConfigLine([string]$cfg, [string]$key, [string]$value) {
    $lines = Get-Content $cfg
    $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*;?\s*$key\s*=") { if (-not $done) { $lines[$i] = "$key = $value"; $done = $true } else { $lines[$i] = "; " + ($lines[$i] -replace '^\s*;\s*', '') } }
    }
    if (-not $done) { $lines += "$key = $value" }
    Set-Content $cfg $lines -Encoding ASCII
}

$game = Find-GameDir
$win64 = Join-Path $game 'Win64'
$res = Join-Path $game 'game\res'
$backup = Join-Path $game 'goo4k-backup'
$cfgDir = Join-Path $env:LOCALAPPDATA '2DBoy\WorldOfGoo'
Write-Host "Game folder: $game"

if ($Uninstall) {
    foreach ($f in 'WorldOfGoo.exe', 'SDL2.dll') {
        $b = Join-Path $backup $f
        if (Test-Path $b) { Copy-Item $b (Join-Path $win64 $f) -Force; Write-Host "  restored $f" }
    }
    $b = Join-Path $backup 'resources.xml'
    if (Test-Path $b) { Copy-Item $b (Join-Path $game 'game\properties\resources.xml') -Force; Write-Host "  restored resources.xml" }
    Remove-Item (Join-Path $win64 'SDL2_real.dll') -ErrorAction SilentlyContinue
    $list = Join-Path $backup 'installed-textures.txt'
    if (Test-Path $list) { $n = 0; foreach ($rel in Get-Content $list) { $t = Join-Path $res $rel; if (Test-Path $t) { Remove-Item $t; $n++ } }; Write-Host "  removed $n texture files" }
    Write-Host "Uninstalled. Config lines (framebuffer, vsync) were left as they are."
    exit 0
}

if (Get-Process WorldOfGoo -ErrorAction SilentlyContinue) { throw "World of Goo is running. Close it first." }
try { $probe = Join-Path $win64 'goo4k-writetest'; [IO.File]::WriteAllText($probe, ''); Remove-Item $probe }
catch { throw "No write access to $win64. Run this from an elevated (Administrator) PowerShell, or fix the folder permissions." }

Write-Host "Patching:"
Apply-Manifest (Join-Path $here 'patches\WorldOfGoo.exe.json') (Join-Path $win64 'WorldOfGoo.exe') $backup
# stock SDL2.dll becomes SDL2_real.dll (patched), the shim takes its name
$sdl = Join-Path $win64 'SDL2.dll'; $real = Join-Path $win64 'SDL2_real.dll'
$m = Get-Content (Join-Path $here 'patches\SDL2_real.dll.json') -Raw | ConvertFrom-Json
if (-not (Test-Path $real)) {
    if ((Sha256 $sdl) -ne $m.stock_sha256) { throw "SDL2.dll: unexpected file. Verify game files in Steam and retry." }
    Copy-Item $sdl $real -Force
}
Apply-Manifest (Join-Path $here 'patches\SDL2_real.dll.json') $real $backup
if (-not (Test-Path (Join-Path $backup 'SDL2.dll'))) { New-Item -ItemType Directory -Force $backup | Out-Null; Copy-Item $sdl (Join-Path $backup 'SDL2.dll') -Force }
Copy-Item (Join-Path $here 'files\SDL2.dll') $sdl -Force
Write-Host "  SDL2.dll: presentation shim installed (stock kept as SDL2_real.dll)"

# fonts: resources.xml with the font atlases rasterised at 4x (the exe hook mipmaps them)
$resFile = Join-Path $game 'game\properties\resources.xml'
$resJson = Join-Path $here 'patches\resources.xml.json'
if ((Test-Path $resJson) -and (Test-Path $resFile)) {
    $r = Get-Content $resJson -Raw | ConvertFrom-Json
    $cur = Sha256 $resFile
    if ($cur -eq $r.patched_sha256) { Write-Host "  resources.xml: already patched" }
    elseif ($cur -eq $r.stock_sha256) {
        New-Item -ItemType Directory -Force $backup | Out-Null
        Copy-Item $resFile (Join-Path $backup 'resources.xml') -Force
        Copy-Item (Join-Path $here 'files\resources.xml') $resFile -Force
        Write-Host "  resources.xml: $($r.fonts) fonts rasterised at $($r.factor)x"
    } else { Write-Host "  resources.xml: not the stock file (edited or another mod?), fonts left as they are" -ForegroundColor Yellow }
}

$tex = Join-Path $here 'textures\res'
if (-not $NoTextures -and (Test-Path $tex)) {
    $n = 0; $list = @()
    Get-ChildItem $tex -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($tex.Length + 1)
        $dst = Join-Path $res $rel
        New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
        Copy-Item $_.FullName $dst -Force; $n++; $list += $rel
    }
    Set-Content (Join-Path $backup 'installed-textures.txt') $list
    Write-Host "  textures: $n files installed"
} elseif ($NoTextures) { Write-Host "  textures: skipped" }
else { Write-Host "  textures: none found next to the installer (put the texture pack's 'textures' folder here), skipped" }

$cfg = Join-Path $cfgDir 'config.ini'
if (Test-Path $cfg) {
    Add-Type -AssemblyName System.Windows.Forms
    try { [void][DpiHelper] } catch { Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public class DpiHelper { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }' }
    [DpiHelper]::SetProcessDPIAware() | Out-Null
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    Set-ConfigLine $cfg 'use_fbo' '1'
    Set-ConfigLine $cfg 'fbo_width' "$($b.Width)"
    Set-ConfigLine $cfg 'fbo_height' "$($b.Height)"
    Set-ConfigLine $cfg 'vsync' '-1'
    Write-Host "  config: framebuffer $($b.Width)x$($b.Height), vsync adaptive"
} else { Write-Host "  config: not found yet (run the game once), framebuffer lines not set" }
Write-Host "Done. Launch World of Goo from Steam as usual. To remove: uninstall.cmd"
