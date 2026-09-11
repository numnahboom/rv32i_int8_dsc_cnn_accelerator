param(
    [ValidateSet('retime-remap', 'retime-only')]
    [string]$Recipe = 'retime-remap'
)
$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$wrapper = (Resolve-Path (Join-Path $PSScriptRoot "run_cnn_top_group_shared64_full_impl.ps1")).Path
$baseOut = Join-Path $projectRoot "build\reports\vivado_cnn_top_retime_remap_full_impl_20260909"
$runId = "{0}-{1}-{2}" -f $Recipe, (Get-Date -Format "yyyyMMddTHHmmssfff"), $PID
$outDir = Join-Path $baseOut (Join-Path "runs" $runId)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# The base wrapper keeps the ordinary full-top production defaults.  These
# extra variables are the only experiment-specific controls and are restored
# on exit so invoking this recipe cannot alter the caller's environment.  The
# second recipe isolates synthesis/post-place retiming from the remap directive
# after the combined experiment produced a materially different result.
$optRemap = if ($Recipe -eq 'retime-remap') { 'explore_with_remap' } else { $null }
$optDirective = if ($Recipe -eq 'retime-only') { 'Explore' } else { $null }
$experimentValues = @{
    'VIVADO_IMPL_OUT_DIR_OVERRIDE' = $outDir
    'VIVADO_IMPL_RUN_ID_OVERRIDE' = $runId
    'VIVADO_IMPL_SYNTH_GLOBAL_RETIMING' = 'on'
    'VIVADO_IMPL_RECIPE' = $Recipe
    'VIVADO_IMPL_OPT_REMAP' = $optRemap
    'VIVADO_IMPL_OPT_DIRECTIVE' = $optDirective
    'VIVADO_IMPL_PLACE_DIRECTIVE' = 'Explore'
    'VIVADO_IMPL_PHYS_OPT_RETIME' = 'true'
    'VIVADO_IMPL_ROUTE_DIRECTIVE' = 'AggressiveExplore'
}
$saved = @{}
foreach ($name in $experimentValues.Keys) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, $experimentValues[$name], 'Process')
}

$manifestFile = Join-Path $outDir 'manifest.txt'
$launchError = $null
$exitCode = $null
try {
    try {
        & $wrapper
        $exitCode = $LASTEXITCODE
    } catch {
        $launchError = $_
        $exitCode = $LASTEXITCODE
    }
} finally {
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) {
            Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
    }
}

if (-not (Test-Path -LiteralPath $manifestFile)) {
    throw "retime/remap recipe produced no manifest (exit=$exitCode); output=$outDir"
}
if ($launchError) {
    throw "retime/remap recipe failed (exit=$exitCode): $launchError (see $manifestFile)"
}
if ($exitCode -ne 0) {
    throw "retime/remap recipe failed with exit code $exitCode (see $manifestFile)"
}
Write-Output "retime/remap full-top implementation completed: $outDir"
