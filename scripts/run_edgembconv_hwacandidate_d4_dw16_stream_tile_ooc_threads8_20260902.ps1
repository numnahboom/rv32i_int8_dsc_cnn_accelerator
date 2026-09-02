$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$vivado = 'D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat'
if (!(Test-Path -LiteralPath $vivado)) { throw "Vivado not found: $vivado" }
& $vivado -mode batch -source (Join-Path $root 'scripts\vivado_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902.tcl') -log (Join-Path $root 'build\vivado_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902.log') -journal (Join-Path $root 'build\vivado_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902.jou')
if ($LASTEXITCODE -ne 0) { throw "Vivado failed with exit code $LASTEXITCODE" }
