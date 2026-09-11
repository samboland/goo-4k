# goo-4k installer. Run in PowerShell:
#   irm https://raw.githubusercontent.com/samboland/goo-4k/main/get.ps1 | iex
# Non-interactive use (wrap in a scriptblock to pass options):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/samboland/goo-4k/main/get.ps1))) -Yes -NoTextures
#   -Yes                 accept defaults, no prompts
#   -NoTextures          engine patches only
#   -Uninstall           restore the stock files
#   -GameDir <path>      the folder containing Win64 and game (skips detection)
#   -From <folder>       take the zips from a local folder instead of GitHub (testing)
param(
    [switch]$Yes,
    [switch]$NoTextures,
    [switch]$Uninstall,
    [string]$GameDir = "",
    [string]$From = ""
)
$ErrorActionPreference = 'Stop'
$repo = 'samboland/goo-4k'
$work = Join-Path $env:TEMP 'goo4k-install'
New-Item -ItemType Directory -Force $work | Out-Null

function Ask([string]$question, [string]$default) {
    if ($Yes) { return $default }
    $hint = if ($default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$question $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a.Trim().ToLower().Substring(0, 1)
}

function Find-GameDir {
    if ($GameDir) {
        if (Test-Path (Join-Path $GameDir 'Win64\WorldOfGoo.exe')) { return (Resolve-Path $GameDir).Path }
        throw "No Win64\WorldOfGoo.exe under $GameDir"
    }
    $candidates = @("${env:ProgramFiles(x86)}\Steam\steamapps\common\World of Goo", "$env:ProgramFiles\Steam\steamapps\common\World of Goo")
    $vdf = "${env:ProgramFiles(x86)}\Steam\steamapps\libraryfolders.vdf"
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $candidates += ($m.Groups[1].Value -replace '\\\\', '\') + '\steamapps\common\World of Goo'
        }
    }
    foreach ($c in $candidates) { if (Test-Path (Join-Path $c 'Win64\WorldOfGoo.exe')) { return $c } }
    return $null
}

function Fetch([string]$url, [string]$dest) {
    if (Test-Path $url) { Copy-Item $url $dest -Force; return }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) { & $curl.Source -L --progress-bar -o $dest $url; if ($LASTEXITCODE -ne 0) { throw "download failed: $url" } }
    else { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest }
}

# ---- release
if ($From) {
    $installerZip = Get-ChildItem (Join-Path $From 'goo4k-*.zip') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'goo4k-textures-*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $texturesZip = Get-ChildItem (Join-Path $From 'goo4k-textures-*.zip') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $installerZip) { throw "no goo4k-*.zip in $From" }
    $installerUrl = $installerZip.FullName
    $texturesUrl = if ($texturesZip) { $texturesZip.FullName } else { $null }
    $texturesMB = if ($texturesZip) { [math]::Round($texturesZip.Length / 1MB) } else { 0 }
    $tag = 'local'
} else {
    $rel = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases/latest"
    $tag = $rel.tag_name
    $inst = $rel.assets | Where-Object { $_.name -like 'goo4k-*.zip' -and $_.name -notlike 'goo4k-textures-*' } | Select-Object -First 1
    $texa = $rel.assets | Where-Object { $_.name -like 'goo4k-textures-*.zip' } | Select-Object -First 1
    if (-not $inst) { throw "release $tag has no installer zip" }
    $installerUrl = $inst.browser_download_url
    $texturesUrl = if ($texa) { $texa.browser_download_url } else { $null }
    $texturesMB = if ($texa) { [math]::Round($texa.size / 1MB) } else { 0 }
}
Write-Host ""
Write-Host "goo-4k $tag" -ForegroundColor Cyan
Write-Host "4K rendering, 4x art and high-refresh motion for World of Goo (Steam)."
Write-Host ""

# ---- game folder
$game = Find-GameDir
if ($game) {
    Write-Host "Found World of Goo at: $game"
    if ((Ask "Use this folder?" 'y') -ne 'y') { $game = $null }
}
while (-not $game) {
    if ($Yes) { throw "World of Goo not found. Pass -GameDir." }
    $p = Read-Host "Path to the World of Goo folder (the one containing Win64 and game)"
    if (Test-Path (Join-Path $p 'Win64\WorldOfGoo.exe')) { $game = (Resolve-Path $p).Path } else { Write-Host "No Win64\WorldOfGoo.exe there." -ForegroundColor Yellow }
}
if (Get-Process WorldOfGoo -ErrorAction SilentlyContinue) { throw "World of Goo is running. Close it and run this again." }

# ---- installer files
$dir = Join-Path $work $tag
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $dir | Out-Null
Write-Host "Fetching installer..."
Fetch $installerUrl (Join-Path $work 'installer.zip')
Expand-Archive (Join-Path $work 'installer.zip') $dir -Force
$inner = Get-ChildItem $dir -Directory | Select-Object -First 1
$installDir = if ($inner -and (Test-Path (Join-Path $inner.FullName 'install.ps1'))) { $inner.FullName } else { $dir }

# ---- already installed?
$manifest = Get-Content (Join-Path $installDir 'patches\WorldOfGoo.exe.json') -Raw | ConvertFrom-Json
$exeHash = (Get-FileHash -Algorithm SHA256 (Join-Path $game 'Win64\WorldOfGoo.exe')).Hash.ToLower()
$installed = $exeHash -eq $manifest.patched_sha256
$backupExists = Test-Path (Join-Path $game 'goo4k-backup\WorldOfGoo.exe')
if ($Uninstall) {
    $mode = 'r'
} elseif ($installed -or ($backupExists -and $exeHash -ne $manifest.stock_sha256)) {
    Write-Host ""
    Write-Host ($(if ($installed) { "This version is already installed." } else { "A different goo-4k version is installed." }))
    Write-Host "  [U] Update or reinstall (default)"
    Write-Host "  [R] Remove goo-4k and restore the stock files"
    Write-Host "  [Q] Quit"
    $mode = if ($Yes) { 'u' } else { $a = Read-Host "Choice"; if ([string]::IsNullOrWhiteSpace($a)) { 'u' } else { $a.Trim().ToLower().Substring(0, 1) } }
    if ($mode -eq 'q') { return }
} else {
    $mode = 'u'
}

# ---- textures
$wantTextures = $false
if ($mode -eq 'u' -and -not $NoTextures) {
    if ($texturesUrl) {
        Write-Host ""
        Write-Host "The texture pack is every game image at 4x native resolution ($texturesMB MB download)."
        Write-Host "Without it you still get native-resolution rendering and smooth motion, with the stock art."
        $wantTextures = (Ask "Install the texture pack?" 'y') -eq 'y'
    } else {
        Write-Host "This release has no texture pack; installing the engine patches only."
    }
}
if ($wantTextures) {
    Write-Host "Fetching texture pack ($texturesMB MB)..."
    Fetch $texturesUrl (Join-Path $work 'textures.zip')
    Expand-Archive (Join-Path $work 'textures.zip') $installDir -Force
}

# ---- go
Write-Host ""
$installArgs = @{ GameDir = $game }
if ($mode -eq 'r') { $installArgs.Uninstall = $true }
if (-not $wantTextures) { $installArgs.NoTextures = $true }
& (Join-Path $installDir 'install.ps1') @installArgs
Write-Host ""
if (-not $Yes) { Read-Host "Press Enter to close" | Out-Null }
