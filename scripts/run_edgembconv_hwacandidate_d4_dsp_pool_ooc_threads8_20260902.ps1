param(
    [string]$Vivado = "D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat"
)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$out = Join-Path $root "build\reports\vivado_edgembconv_hwacandidate_d4_dsp_pool_ooc_threads8_20260902"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$tcl = (Resolve-Path (Join-Path $PSScriptRoot "vivado_edgembconv_hwacandidate_d4_dsp_pool_ooc_threads8_20260902.tcl")).Path
$log = Join-Path $out "vivado.log"
$jou = Join-Path $out "vivado.jou"
$console = Join-Path $out "vivado_console.txt"
$oldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $Vivado -mode batch -notrace -log $log -journal $jou -source $tcl *> $console
$vivadoExitCode = $LASTEXITCODE
$ErrorActionPreference = $oldErrorActionPreference
if ($vivadoExitCode -ne 0) { throw "Vivado OOC route failed with exit code $vivadoExitCode; see $console" }
if (-not (Test-Path (Join-Path $out "timing_summary_post_route.txt"))) {
    throw "Vivado exited without post-route timing report; see $console"
}
Write-Output "PASS $out"
