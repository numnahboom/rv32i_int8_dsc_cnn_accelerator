param(
    [string]$Vivado = "D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat",
    [string]$Part = "xck26-sfvc784-2LV-c",
    [string]$Top = "cnn_top"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$TclScript = Join-Path $ProjectRoot "scripts\vivado_cnn_top_synth.tcl"
$OutDir = Join-Path $ProjectRoot "build\reports\vivado_$Top"
$LogFile = Join-Path $OutDir "vivado.log"
$JournalFile = Join-Path $OutDir "vivado.jou"
$ConsoleFile = Join-Path $OutDir "vivado_console.txt"

if (-not (Test-Path $Vivado)) {
    $cmd = Get-Command vivado -ErrorAction SilentlyContinue
    if ($cmd) {
        $Vivado = $cmd.Source
    } else {
        throw "Vivado executable not found. Pass -Vivado <path-to-vivado.bat>."
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Vivado 2021.2 otherwise derives a malformed local Tcl-store path ("C")
# from HOMEDRIVE on this Windows setup and emits Common 17-741.  HOME is
# inherited only by this wrapper and its child process.
if (-not $env:HOME -and $env:USERPROFILE) {
    $env:HOME = $env:USERPROFILE
}

Push-Location $ProjectRoot
try {
    & $Vivado -mode batch -notrace -log $LogFile -journal $JournalFile -source $TclScript -tclargs $Top $Part *> $ConsoleFile
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado exited with code $LASTEXITCODE. See $LogFile"
    }
} finally {
    Pop-Location
}

if ($Top -eq "cnn_top") {
    Get-Content (Join-Path $ProjectRoot "docs\reports\synthesis_vivado_initial.md")
} else {
    Get-Content (Join-Path $ProjectRoot "docs\reports\synthesis_vivado_$Top.md")
}
