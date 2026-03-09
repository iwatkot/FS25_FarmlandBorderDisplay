$gamePath = "C:\Games\Steam\steamapps\common\Farming Simulator 25"
$runner   = Join-Path $PSScriptRoot "..\TestRunner_public.exe"
$modDir   = Join-Path $PSScriptRoot "..\FS25_FarmlandsBorderDisplay"

& $runner $modDir -g $gamePath --noPause
