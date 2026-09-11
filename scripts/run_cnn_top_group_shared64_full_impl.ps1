$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$vivado = "D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat"
$tclScript = (Resolve-Path (Join-Path $projectRoot "scripts\vivado_cnn_top_impl.tcl")).Path
$part = "xc7z020clg400-1"
$top = "cnn_top"

# Every invocation is isolated so reports, checkpoints, and the architecture
# proof remain attributable to one production generic and one source snapshot.
$requestedOut = $env:VIVADO_IMPL_OUT_DIR_OVERRIDE
$runId = if (-not [string]::IsNullOrWhiteSpace($env:VIVADO_IMPL_RUN_ID_OVERRIDE)) {
    $env:VIVADO_IMPL_RUN_ID_OVERRIDE
} else {
    "{0:yyyyMMddTHHmmssfff}-{1}" -f (Get-Date), $PID
}
$baseOut = Join-Path $projectRoot "build\reports\vivado_cnn_top_group_shared64_full_impl"
$outDir = if ([string]::IsNullOrWhiteSpace($requestedOut)) {
    Join-Path $baseOut (Join-Path "runs" $runId)
} else {
    [IO.Path]::GetFullPath($requestedOut)
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$outDir = (Resolve-Path -LiteralPath $outDir).Path
$outDirForTcl = $outDir.Replace('\', '/')
$logFile = Join-Path $outDir "vivado.log"
$journalFile = Join-Path $outDir "vivado.jou"
$consoleFile = Join-Path $outDir "vivado_console.txt"
$manifestFile = Join-Path $outDir "manifest.txt"

$runningVivado = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match '^(vivado|vivado_lab|vivado_hls)$' }
if ($null -ne $runningVivado) {
    $names = ($runningVivado | ForEach-Object { "$($_.ProcessName)#$($_.Id)" }) -join ', '
    throw "Refusing concurrent Vivado implementation; running process(es): $names"
}

if (-not (Test-Path -LiteralPath $vivado)) {
    throw "Vivado executable not found: $vivado"
}

$saved = @{}
foreach ($name in @(
    'VIVADO_IMPL_OUT_DIR','VIVADO_IMPL_CONSTRAINT_FILE',
    'VIVADO_IMPL_CLOCK_PERIOD_NS','VIVADO_IMPL_DIRECTIVE',
    'VIVADO_IMPL_MAX_THREADS','VIVADO_IMPL_SYNTH_GENERIC',
    'VIVADO_IMPL_SYNTH_MODE','VIVADO_IMPL_REQUIRE_NO_LEGACY_DS',
    'VIVADO_IMPL_REQUIRE_GROUP_SHARED64','VIVADO_IMPL_RUN_ID',
    'VIVADO_IMPL_SYNTH_GLOBAL_RETIMING','VIVADO_IMPL_OPT_REMAP',
    'VIVADO_IMPL_OPT_DIRECTIVE','VIVADO_IMPL_PLACE_DIRECTIVE',
    'VIVADO_IMPL_PHYS_DIRECTIVE','VIVADO_IMPL_PHYS_OPT_RETIME',
    'VIVADO_IMPL_ROUTE_DIRECTIVE','HOME')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$env:VIVADO_IMPL_OUT_DIR = $outDirForTcl
$env:VIVADO_IMPL_CONSTRAINT_FILE = "constraints/cnn_top_group_shared64_fulltop_8ns.xdc"
$env:VIVADO_IMPL_CLOCK_PERIOD_NS = "8.000"
# The complete cnn_top hierarchy is still synthesized and implemented; OOC
# mode is required because this core-level run intentionally has no package
# pin assignment for the 201 top-level ports.
$env:VIVADO_IMPL_SYNTH_MODE = "out_of_context"
# The production physical variant routes DS1-DS6 through one group-published
# shared64 backend while retaining the normal Stem/GAP/FC hierarchy.  The
# unified64 Stem is a separate simulation stress option and would add enough
# DSPs to exceed the XC7Z020 device envelope in this full-top run.
$env:VIVADO_IMPL_SYNTH_GENERIC = "USE_GROUP_SHARED64_DS=1"
$env:VIVADO_IMPL_REQUIRE_NO_LEGACY_DS = "1"
$env:VIVADO_IMPL_REQUIRE_GROUP_SHARED64 = "1"
$env:VIVADO_IMPL_DIRECTIVE = "Explore"
$env:VIVADO_IMPL_MAX_THREADS = "8"
$env:VIVADO_IMPL_RUN_ID = $runId
if ([string]::IsNullOrWhiteSpace($env:HOME) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $env:HOME = $env:USERPROFILE
}

$launchError = $null
$exitCode = $null
try {
    Push-Location -LiteralPath $outDir
    try {
        & $vivado -mode batch -notrace -log ($logFile.Replace('\', '/')) -journal ($journalFile.Replace('\', '/')) `
            -source ($tclScript.Replace('\', '/')) -tclargs $top $part *> $consoleFile
        $exitCode = $LASTEXITCODE
    } catch {
        $launchError = $_
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
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
    throw "group shared64 full-top implementation produced no manifest (exit=$exitCode); see $logFile"
}
$manifest = Get-Content -LiteralPath $manifestFile -Raw
if ($manifest -match '(?m)^status:\s*RUNNING\s*$') {
    $detail = if ($launchError) { $launchError.ToString() } else { "Vivado exited before Tcl finalization" }
    $detail = ($detail -replace "`r?`n", ' | ') + "; exit_code=$exitCode"
    $manifestLines = Get-Content -LiteralPath $manifestFile
    $manifestLines = foreach ($line in $manifestLines) {
        if ($line -match '^status:\s*RUNNING\s*$') { "status: FAILED_WRAPPER_OR_VIVADO_START" }
        elseif ($line -match '^detail:') { "detail: $detail" }
        else { $line }
    }
    Set-Content -LiteralPath $manifestFile -Value $manifestLines -Encoding utf8
}
$finalManifest = Get-Content -LiteralPath $manifestFile -Raw
$statusMatch = [regex]::Match($finalManifest, '(?m)^status:\s*(.+?)\s*$')
$finalStatus = if ($statusMatch.Success) { $statusMatch.Groups[1].Value } else { "UNPARSEABLE" }
# Vivado returns a non-zero code when the Tcl flow deliberately raises its
# evidence-backed FAILED_TIMING_CLOSURE result. Preserve that completed run so
# the caller can classify it as NEGATIVE_RESULT instead of losing the DCP and
# reports behind a wrapper-launch error.
if ($finalStatus -eq "FAILED_TIMING_CLOSURE") {
    Write-Output "group shared64 full-top implementation completed with negative timing result: $outDir"
    exit 0
}
if ($launchError) { throw "group shared64 full-top Vivado launcher failed (exit=$exitCode): $launchError (see $manifestFile)" }
if ($exitCode -ne 0) { throw "group shared64 full-top 8 ns implementation failed: $exitCode (see $manifestFile)" }
Write-Output "group shared64 full-top implementation completed: $outDir"
