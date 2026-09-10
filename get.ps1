# goo-4k one-line installer
#   irm https://raw.githubusercontent.com/samboland/goo-4k/main/get.ps1 | iex
# Options (wrap in a scriptblock to pass them):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/samboland/goo-4k/main/get.ps1))) -NoTextures
#   ... -Uninstall            restore the stock files
#   ... -GameDir <path>       if the Steam folder is not found automatically
#   ... -From <folder|url>    take the installer/texture zips from a local folder or URL prefix (testing)
param(
    [switch]$NoTextures,
    [switch]$Uninstall,
    [string]$GameDir = "",
    [string]$From = ""
)
$ErrorActionPreference = 'Stop'
$repo = 'samboland/goo-4k'
$work = Join-Path $env:TEMP 'goo4k-install'
New-Item -ItemType Directory -Force $work | Out-Null

function Fetch([string]$url, [string]$dest) {
    if (Test-Path $url) { Copy-Item $url $dest -Force; return }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) { & $curl.Source -L --progress-bar -o $dest $url; if ($LASTEXITCODE -ne 0) { throw "download failed: $url" } }
    else { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest }
}

if ($From) {
    $installerZip = Get-ChildItem (Join-Path $From 'goo4k-*.zip') -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'goo4k-textures-*' } | Select-Object -First 1
    $texturesZip = Get-ChildItem (Join-Path $From 'goo4k-textures-*.zip') -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $installerZip) { throw "no goo4k-*.zip in $From" }
    $installerUrl = $installerZip.FullName; $texturesUrl = if ($texturesZip) { $texturesZip.FullName } else { $null }
    $tag = 'local'
} else {
    $rel = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases/latest"
    $tag = $rel.tag_name
    $installerUrl = ($rel.assets | Where-Object { $_.name -like 'goo4k-*.zip' -and $_.name -notlike 'goo4k-textures-*' } | Select-Object -First 1).browser_download_url
    $texturesUrl  = ($rel.assets | Where-Object { $_.name -like 'goo4k-textures-*.zip' } | Select-Object -First 1).browser_download_url
    if (-not $installerUrl) { throw "release $tag has no installer zip" }
}
Write-Host "goo-4k $tag"

$dir = Join-Path $work $tag
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force $dir | Out-Null
Write-Host "Downloading installer..."
Fetch $installerUrl (Join-Path $work 'installer.zip')
Expand-Archive (Join-Path $work 'installer.zip') $dir -Force
$inner = Get-ChildItem $dir -Directory | Select-Object -First 1
$installDir = if ($inner -and (Test-Path (Join-Path $inner.FullName 'install.ps1'))) { $inner.FullName } else { $dir }

if (-not $Uninstall -and -not $NoTextures) {
    if ($texturesUrl) {
        Write-Host "Downloading texture pack (large)..."
        Fetch $texturesUrl (Join-Path $work 'textures.zip')
        Expand-Archive (Join-Path $work 'textures.zip') $installDir -Force
    } else { Write-Host "No texture pack in this release; installing the engine patches only." }
}

$installArgs = @{}
if ($GameDir) { $installArgs.GameDir = $GameDir }
if ($Uninstall) { $installArgs.Uninstall = $true }
if ($NoTextures) { $installArgs.NoTextures = $true }
& (Join-Path $installDir 'install.ps1') @installArgs
