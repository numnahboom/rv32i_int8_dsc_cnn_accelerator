param(
    [string]$Vivado='D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat',
    [string]$RunId=(Get-Date -Format 'yyyyMMdd_HHmmss'),
    [switch]$SynthOnly,
    [switch]$PrepareOnly
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$mode=if($SynthOnly){'synth'}else{'route'}
$out=Join-Path $root "build/reports/d4_fullnet_${mode}_$RunId"
if(Test-Path -LiteralPath $out){throw "Refusing existing output: $out"}
if(!(Test-Path -LiteralPath $Vivado)){throw "Vivado missing: $Vivado"}
New-Item -ItemType Directory -Path $out | Out-Null
$files=@('rtl/cnn/d4_fullnet_clocking.sv','rtl/cnn/d4_fullnet_top.sv','rtl/cnn/d4_fullnet_impl_top.sv',
    'constraints/d4_fullnet_8ns.xdc','scripts/vivado_d4_fullnet.tcl',
    'scripts/run_d4_fullnet_impl.ps1','python/export_d4_fullnet_vectors.py',
    'sim/tb_d4_fullnet_packed.sv')
$files+=Get-ChildItem -LiteralPath (Join-Path $root 'build/d4_fullnet_vectors/sample_0') -Filter '*.mem' |
    ForEach-Object {$_.FullName.Substring($root.Length+1).Replace('\','/')}
$records=foreach($file in $files){
    $path=Join-Path $root $file
    @{path=$file;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
}
$snapshot=Join-Path $out 'sources'
foreach($file in $files){
    $destination=Join-Path $snapshot $file
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination $destination
}
@{stage=$mode;head=(git -C $root rev-parse HEAD);files=@($records)} |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'source_manifest.json') -Encoding utf8
if($PrepareOnly){
    Write-Output "IMPLEMENTATION_PREPARED stage=$mode reports=$out (Vivado not started)"
    return
}
$previous=$ErrorActionPreference
$ErrorActionPreference='Continue'
try {
    & $Vivado -mode batch -notrace -source (Join-Path $snapshot 'scripts/vivado_d4_fullnet.tcl') `
        -log (Join-Path $out 'vivado.log') -journal (Join-Path $out 'vivado.jou') `
        -tclargs $out $mode *> (Join-Path $out 'console.log')
    $code=$LASTEXITCODE
} finally {$ErrorActionPreference=$previous}
if($code -ne 0){throw "Vivado failed exit=$code; $out/console.log"}
$expected=if($SynthOnly){'timing_synth.txt'}else{'timing_post_route.txt'}
if(!(Test-Path -LiteralPath (Join-Path $out $expected))){throw "Missing $expected in $out"}
Write-Output "IMPLEMENTATION_COMPLETED stage=$mode reports=$out (inspect reports for target acceptance)"
