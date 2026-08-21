param(
    [string]$Vivado = "D:\Software\Xilinx\Vivado\2021.2\bin\vivado.bat",
    [string]$Part = "xck26-sfvc784-2LV-c",
    [string]$Top = "cnn_top"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$TclScript = Join-Path $ProjectRoot "scripts\vivado_cnn_top_impl.tcl"
$BaseOutDir = Join-Path $ProjectRoot "build\reports\vivado_${Top}_impl"
$RunId = "{0:yyyyMMddTHHmmssfff}-{1}" -f (Get-Date), $PID
$OutDir = Join-Path $BaseOutDir (Join-Path "runs" $RunId)
$LogFile = Join-Path $OutDir "vivado.log"
$JournalFile = Join-Path $OutDir "vivado.jou"
$ConsoleFile = Join-Path $OutDir "vivado_console.txt"
$ManifestFile = Join-Path $OutDir "manifest.txt"

function Write-WrapperManifest {
    param(
        [string]$Status,
        [string]$Detail
    )

    @(
        "format: cnn-vivado-implementation-manifest-v2"
        "run_id: $RunId"
        "timestamp: $((Get-Date).ToString('o'))"
        "top: $Top"
        "part: $Part"
        "status: $Status"
        "detail: $($Detail -replace "`r?`n", ' | ')"
        "wrapper: scripts/run_cnn_impl.ps1"
    ) | Set-Content -LiteralPath $ManifestFile -Encoding utf8
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# Each invocation receives an isolated run directory.  This sentinel makes a
# launch failure distinguishable from a previous Vivado result.
Write-WrapperManifest -Status "RUNNING" -Detail "Vivado has not completed yet."

if (-not (Test-Path -LiteralPath $Vivado)) {
    $cmd = Get-Command vivado -ErrorAction SilentlyContinue
    if ($cmd) {
        $Vivado = $cmd.Source
    } else {
        Write-WrapperManifest -Status "FAILED_WRAPPER_START" -Detail "Vivado executable not found: $Vivado"
        throw "Vivado executable not found. Pass -Vivado <path-to-vivado.bat>."
    }
}

if (-not (Test-Path -LiteralPath $TclScript)) {
    Write-WrapperManifest -Status "FAILED_WRAPPER_START" -Detail "Tcl script not found: $TclScript"
    throw "Tcl script not found: $TclScript"
}

$previousOutDir = $env:VIVADO_IMPL_OUT_DIR
$previousRunId = $env:VIVADO_IMPL_RUN_ID
$previousHome = $env:HOME
$env:VIVADO_IMPL_OUT_DIR = $OutDir
$env:VIVADO_IMPL_RUN_ID = $RunId
if ([string]::IsNullOrWhiteSpace($env:HOME) -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    # Vivado otherwise falls back to the drive root for its local Tcl store,
    # which is commonly non-writable on managed Windows installations.
    $env:HOME = $env:USERPROFILE
}
$vivadoExitCode = $null
$wrapperError = $null
# Vivado creates a local .Xil directory below its working directory.  Running
# from this invocation's unique output directory prevents concurrent/stale
# runs from contending for <project>/.Xil while the Tcl script still resolves
# every source and constraint path from its own absolute script directory.
Push-Location $OutDir
try {
    & $Vivado -mode batch -notrace -log $LogFile -journal $JournalFile `
        -source $TclScript -tclargs $Top $Part *> $ConsoleFile
    $vivadoExitCode = $LASTEXITCODE
} catch {
    $wrapperError = $_
} finally {
    Pop-Location
    $env:VIVADO_IMPL_OUT_DIR = $previousOutDir
    $env:VIVADO_IMPL_RUN_ID = $previousRunId
    $env:HOME = $previousHome
}

if ($wrapperError) {
    Write-WrapperManifest -Status "FAILED_WRAPPER_START" -Detail $wrapperError.ToString()
    throw $wrapperError
}

$manifestText = Get-Content -LiteralPath $ManifestFile -Raw
if ($manifestText -match "(?m)^status: RUNNING$") {
    Write-WrapperManifest -Status "FAILED_WRAPPER_OR_VIVADO_START" -Detail "Vivado exited before writing a final manifest. exit_code=$vivadoExitCode"
    $manifestText = Get-Content -LiteralPath $ManifestFile -Raw
}
$statusMatch = [regex]::Match($manifestText, "(?m)^status:\s*(.+?)\s*$")
if (-not $statusMatch.Success) {
    Write-WrapperManifest -Status "FAILED_WRAPPER_OR_VIVADO_START" -Detail "Final manifest did not contain a status field. exit_code=$vivadoExitCode"
    $manifestText = Get-Content -LiteralPath $ManifestFile -Raw
    $statusMatch = [regex]::Match($manifestText, "(?m)^status:\s*(.+?)\s*$")
}
$manifestStatus = if ($statusMatch.Success) { $statusMatch.Groups[1].Value } else { "UNPARSEABLE" }
Get-Content -LiteralPath $ManifestFile

if ($vivadoExitCode -ne 0) {
    throw "Vivado implementation exited with code $vivadoExitCode. See $ManifestFile and $LogFile."
}
if ($manifestStatus -ne "PASSED_TIMING_CLOSURE") {
    throw "Vivado exited with code 0 but manifest status is $manifestStatus, not PASSED_TIMING_CLOSURE. See $ManifestFile and $LogFile."
}
