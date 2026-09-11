param(
    [string]$Vivado = "D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat",
    [string]$RunId = (Get-Date -Format 'yyyyMMdd_HHmmss'),
    [switch]$SynthOnly
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (!(Test-Path -LiteralPath $Vivado)) { throw "Vivado not found: $Vivado" }

$runTag = if ($SynthOnly) { "synth_$RunId" } else { "route_$RunId" }
$out = Join-Path $root ("build\reports\vivado_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_" + $runTag)
if (Test-Path -LiteralPath $out) {
    throw "Refusing to reuse existing OOC run directory: $out"
}
New-Item -ItemType Directory -Force -Path $out | Out-Null

$rtlFiles = @(
    'rtl/cnn/edgembconv_hwacandidate_d4_dsp_pool.v',
    'rtl/cnn/edgembconv_hwacandidate_d4_vstream_elastic_rq_pool.v',
    'rtl/cnn/edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin.v',
    'rtl/cnn/edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_wrapper.v'
)
$constraintFile = 'constraints/edgembconv_hwacandidate_d4_vstream_v6_ooc_8ns.xdc'
$manifest = Join-Path $out 'source_manifest.txt'
$mode = if ($SynthOnly) { 'synth_only' } else { 'route' }
$command = "& `"$Vivado`" -mode batch -notrace -log `"$out\vivado.log`" -journal `"$out\vivado.jou`" -source `"$root\scripts\vivado_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_20260910.tcl`" -tclargs `"$out`" $mode"
$manifestLines = @(
    'format=v6-registered-input-pool-island-ooc-source-manifest-v1',
    "run_id=$RunId",
    "stage=$mode",
    'tool=Vivado 2025.2',
    'device=xc7z020clg400-1',
    'clock_period_ns=8.000',
    'general.maxThreads=8',
    'top=edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_wrapper',
    "constraint=$constraintFile",
    "command=$command"
)
foreach ($relativePath in $rtlFiles + @($constraintFile)) {
    $absolutePath = Join-Path $root $relativePath
    if (!(Test-Path -LiteralPath $absolutePath)) { throw "Missing source: $absolutePath" }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $absolutePath).Hash
    $manifestLines += "source=$relativePath sha256=$hash"
}
Set-Content -LiteralPath $manifest -Value $manifestLines -Encoding UTF8

$tcl = (Resolve-Path (Join-Path $PSScriptRoot 'vivado_edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin_ooc_20260910.tcl')).Path
$console = Join-Path $out 'vivado_console.txt'
& $Vivado -mode batch -notrace -log (Join-Path $out 'vivado.log') -journal (Join-Path $out 'vivado.jou') -source $tcl -tclargs $out $mode *> $console
if ($LASTEXITCODE -ne 0) { throw "v6 registered-input pool OOC $mode failed; see $console" }
if (!(Test-Path -LiteralPath (Join-Path $out 'timing_summary_synth.txt'))) {
    throw "v6 registered-input pool OOC $mode produced no synthesis timing report; see $console"
}
if (!$SynthOnly -and !(Test-Path -LiteralPath (Join-Path $out 'timing_summary_post_route.txt'))) {
    throw "v6 registered-input pool OOC route produced no post-route timing report; see $console"
}
Write-Output "PASS $out"
