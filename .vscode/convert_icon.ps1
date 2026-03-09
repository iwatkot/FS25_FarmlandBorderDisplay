$root    = Join-Path $PSScriptRoot ".."
$texconv = Join-Path $root "texconv.exe"
$src     = Join-Path $root "icon_FarmlandsBorderDisplay.png"
$outDir  = Join-Path $root "FS25_FarmlandsBorderDisplay"

if (-not (Test-Path $texconv)) { Write-Error "texconv.exe not found at $texconv"; exit 1 }
if (-not (Test-Path $src))     { Write-Error "Source PNG not found at $src";      exit 1 }

& $texconv -f BC1_UNORM -m 1 -y -o $outDir $src
Write-Host "Done: $outDir\icon_FarmlandsBorderDisplay.dds"
