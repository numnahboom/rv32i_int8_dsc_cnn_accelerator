param(
    [string]$VivadoBin = 'D:\Software\vivado2025.2\2025.2\Vivado\bin',
    [string]$RunId = 'mmcm_20261018'
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$out=Join-Path $root "build\reports\d4_fullnet_$RunId"
$work=Join-Path $root "build\d4_fullnet_clocking_xsim_$RunId"
New-Item -ItemType Directory -Force -Path $out,$work | Out-Null
$xvlog=Join-Path $VivadoBin 'xvlog.bat'
$xelab=Join-Path $VivadoBin 'xelab.bat'
$xsim=Join-Path $VivadoBin 'xsim.bat'
$versionRoot=Split-Path -Parent (Split-Path -Parent $VivadoBin)
$glbl=Join-Path $versionRoot 'data\verilog\src\glbl.v'
foreach($tool in @($xvlog,$xelab,$xsim,$glbl)){
    if(!(Test-Path -LiteralPath $tool)){throw "XSim input missing: $tool"}
}
$lockPath=Join-Path $root 'build\cnn_xsim.lock'
$lockStream=$null
try {
    $lockStream=[System.IO.File]::Open($lockPath,[System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
} catch {
    throw "Another CNN XSim job owns the shared lock: $lockPath"
}
$log=Join-Path $out 'clocking_unisim.log'
$snapshot='d4_fullnet_clocking_unisim'
Push-Location $work
try {
    & $xvlog -sv -d D4_USE_XILINX_CLOCKING `
        (Join-Path $root 'rtl\cnn\d4_fullnet_clocking.sv') `
        (Join-Path $root 'sim\tb_d4_fullnet_clocking_unisim.sv') $glbl *> $log
    if($LASTEXITCODE -ne 0){throw "xvlog failed; see $log"}
    & $xelab -debug typical tb_d4_fullnet_clocking_unisim glbl `
        -L unisims_ver -L secureip -s $snapshot *>> $log
    if($LASTEXITCODE -ne 0){throw "xelab failed; see $log"}
    & $xsim $snapshot -runall *>> $log
    if($LASTEXITCODE -ne 0){throw "xsim failed; see $log"}
} finally {
    Pop-Location
    if($null -ne $lockStream){$lockStream.Dispose()}
}
$required=@(
    'D4_CLOCKING_NATIVE_LOCK_PASS',
    'D4_CLOCKING_EXTERNAL_RESET_RELOCK_PASS',
    'D4_CLOCKING_INPUT_STOP_LOSS_PASS',
    'D4_CLOCKING_INPUT_RESTART_RELOCK_PASS',
    'D4_CLOCKING_UNISIM_PASS'
)
foreach($marker in $required){
    if(!(Select-String -LiteralPath $log -Pattern $marker -Quiet)){
        throw "Missing native clocking evidence '$marker'; see $log"
    }
}
Select-String -LiteralPath $log -Pattern '^D4_CLOCKING_.*PASS' | ForEach-Object { $_.Line }
Write-Output "PASS native_unisim_clocking log=$log"
