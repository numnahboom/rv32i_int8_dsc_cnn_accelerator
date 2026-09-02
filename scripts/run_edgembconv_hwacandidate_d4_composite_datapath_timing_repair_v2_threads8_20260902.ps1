param([string]$Vivado = "D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat")
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = Join-Path $root 'build\reports\vivado_edgembconv_hwacandidate_d4_composite_datapath_timing_repair_v2_threads8_20260902'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$tcl = (Resolve-Path (Join-Path $PSScriptRoot 'vivado_edgembconv_hwacandidate_d4_composite_datapath_timing_repair_v2_threads8_20260902.tcl')).Path
$console = Join-Path $out 'vivado_console.txt'
& $Vivado -mode batch -notrace -log (Join-Path $out 'vivado.log') -journal (Join-Path $out 'vivado.jou') -source $tcl *> $console
if ($LASTEXITCODE -ne 0) { throw "D4 composite timing-repair v2 OOC failed; see $console" }
if (-not (Test-Path (Join-Path $out 'timing_summary_post_route.txt'))) {
  throw "D4 composite timing-repair v2 OOC produced no timing report; see $console"
}
Write-Output "PASS $out"
