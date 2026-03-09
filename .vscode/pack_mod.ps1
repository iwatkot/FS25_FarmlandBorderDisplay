$root    = Join-Path $PSScriptRoot ".."
$modDir  = Join-Path $root "FS25_FarmlandsBorderDisplay"
$outZip  = Join-Path $root "FS25_FarmlandsBorderDisplay.zip"

if (Test-Path $outZip) { Remove-Item $outZip }

Compress-Archive -Path "$modDir\*" -DestinationPath $outZip
Write-Host "Packed: $outZip"
