param([string]$Vivado = "D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat")
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = Join-Path $root 'build\edgembconv_hwacandidate_d4_composite_datapath_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$vivadoBin = Split-Path -Parent $Vivado
$xvlog = Join-Path $vivadoBin 'xvlog.bat'
$xelab = Join-Path $vivadoBin 'xelab.bat'
$xsim = Join-Path $vivadoBin 'xsim.bat'
$console = Join-Path $out 'console_latest.txt'
Push-Location $root
try {
  & $xvlog -sv (Join-Path $root 'rtl\cnn\edgembconv_hwacandidate_d4_dsp_pool.v') (Join-Path $root 'rtl\cnn\edgembconv_hwacandidate_d4_composite_datapath.v') *> $console
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
  & $xvlog -sv (Join-Path $root 'sim\tb_edgembconv_hwacandidate_d4_composite_datapath.v') *>> $console
  if ($LASTEXITCODE -ne 0) { throw "xvlog testbench failed" }
  & $xelab -debug typical tb_edgembconv_hwacandidate_d4_composite_datapath -s d4_composite_sim_latest *>> $console
  if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
  & $xsim d4_composite_sim_latest -runall *>> $console
  if ($LASTEXITCODE -ne 0) { throw "xsim failed" }
} finally { Pop-Location }
if (-not (Select-String -Path $console -Pattern 'PASS edgembconv_hwacandidate_d4_composite_datapath' -Quiet)) {
  throw "D4 composite simulation did not print PASS; see $out\console.txt"
}
Write-Output "PASS $out"
