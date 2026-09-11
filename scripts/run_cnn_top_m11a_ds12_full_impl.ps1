$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$vivado = "D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat"
$tclScript = (Resolve-Path (Join-Path $projectRoot "scripts\vivado_cnn_top_impl.tcl")).Path
$part = "xc7z020clg400-1"
$top = "cnn_top"

# Every invocation is isolated so its logs, source manifest, reports, and DCP
# cannot collide with another implementation run.
$requestedOut = $env:VIVADO_IMPL_OUT_DIR_OVERRIDE
$runId = if (-not [string]::IsNullOrWhiteSpace($env:VIVADO_IMPL_RUN_ID_OVERRIDE)) {
    $env:VIVADO_IMPL_RUN_ID_OVERRIDE
} else {
    "{0:yyyyMMddTHHmmssfff}-{1}" -f (Get-Date), $PID
}
$baseOut = Join-Path $projectRoot "build\reports\vivado_cnn_top_m11a_ds12_full_impl"
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

$saved = @{}
foreach ($name in @(
    'VIVADO_IMPL_OUT_DIR','VIVADO_IMPL_CONSTRAINT_FILE',
    'VIVADO_IMPL_CLOCK_PERIOD_NS','VIVADO_IMPL_DIRECTIVE',
    'VIVADO_IMPL_MAX_THREADS','VIVADO_IMPL_SYNTH_GENERIC',
    'VIVADO_IMPL_SYNTH_MODE','VIVADO_IMPL_RUN_ID','HOME')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$env:VIVADO_IMPL_OUT_DIR = $outDirForTcl
$env:VIVADO_IMPL_CONSTRAINT_FILE = "constraints/cnn_top_m11a_ds12_fulltop_8ns.xdc"
$env:VIVADO_IMPL_CLOCK_PERIOD_NS = "8.000"
$env:VIVADO_IMPL_SYNTH_MODE = "normal"
$env:VIVADO_IMPL_SYNTH_GENERIC = "USE_M11A_DS1=1"
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
    throw "M1.1-A DS12 full-top implementation produced no manifest (exit=$exitCode); see $logFile"
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
if ($launchError) { throw "M1.1-A DS12 full-top Vivado launcher failed (exit=$exitCode): $launchError (see $manifestFile)" }
if ($exitCode -ne 0) { throw "M1.1-A DS12 full-top 8 ns implementation failed: $exitCode (see $manifestFile)" }
Write-Output "M1.1-A DS12 full-top implementation completed: $outDir"
