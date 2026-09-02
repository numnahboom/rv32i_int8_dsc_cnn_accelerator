param([string]$Vivado = "D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat")
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out = Join-Path $root 'build\edgembconv_hwacandidate_d4_mb16_controller_sim'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$vb = Split-Path -Parent $Vivado
$xvlog = Join-Path $vb 'xvlog.bat'; $xelab = Join-Path $vb 'xelab.bat'; $xsim = Join-Path $vb 'xsim.bat'
$console = Join-Path $out 'console_latest.txt'
Push-Location $root
try {
  & $xvlog -sv -f (Join-Path $root 'sim\filelist_edgembconv_hwacandidate_d4_mb16_controller.f') *> $console
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
  & $xelab -debug typical tb_edgembconv_hwacandidate_d4_mb16_controller -s edgembconv_hwacandidate_d4_mb16_controller_sim *>> $console
  if ($LASTEXITCODE -ne 0) { throw "xelab failed" }
  & $xsim edgembconv_hwacandidate_d4_mb16_controller_sim -runall *>> $console
  if ($LASTEXITCODE -ne 0) { throw "xsim failed" }
} finally { Pop-Location }
if (-not (Select-String -Path $console -Pattern 'PASS edgembconv_hwacandidate_d4_mb16_controller' -Quiet)) { throw "simulation did not print PASS; see $console" }
Write-Output "PASS $console"
