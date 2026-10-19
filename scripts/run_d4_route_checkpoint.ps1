param(
    [Parameter(Mandatory=$true)][string]$SynthDir,
    [string]$RunId=(Get-Date -Format 'yyyyMMdd_HHmmss'),
    [string]$Vivado='D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat',
    [string]$ExpectedCandidate='M',
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedCoreSha256='706CF563CA1F838A337FDA154341F1AF33C6FDEF79A071320AC3259D2F21D529'
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source=(Resolve-Path -LiteralPath $SynthDir).Path
$checkpoint=Join-Path $source 'synth.dcp'
$sourceManifestPath=Join-Path $source 'source_manifest.json'
$acceptancePath=Join-Path $source 'parent_synthesis_acceptance.json'
$snapshotCheckPath=Join-Path $source 'parent_snapshot_check.json'
$sourceSnapshot=Join-Path $source 'sources'
$correctedXdc=Join-Path $root 'constraints/d4_fullnet_8ns.xdc'
if(!(Test-Path -LiteralPath $checkpoint)){throw "Missing checkpoint: $checkpoint"}
if(!(Test-Path -LiteralPath $sourceManifestPath)){throw "Missing source manifest: $sourceManifestPath"}
if(!(Test-Path -LiteralPath $acceptancePath)){throw "Missing parent synthesis acceptance: $acceptancePath"}
if(!(Test-Path -LiteralPath $snapshotCheckPath)){throw "Missing parent snapshot check: $snapshotCheckPath"}
if(!(Test-Path -LiteralPath $sourceSnapshot -PathType Container)){throw "Missing immutable source snapshot: $sourceSnapshot"}
if(!(Test-Path -LiteralPath $correctedXdc)){throw "Missing root-corrected timing constraints: $correctedXdc"}
if(!(Test-Path -LiteralPath $Vivado)){throw "Vivado executable not found: $Vivado"}
$upstreamManifest=Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
$synthesisAcceptance=Get-Content -LiteralPath $acceptancePath -Raw | ConvertFrom-Json
$snapshotCheck=Get-Content -LiteralPath $snapshotCheckPath -Raw | ConvertFrom-Json
$candidateName=[string]$synthesisAcceptance.candidate
if($candidateName -ne $ExpectedCandidate){throw "This route contract requires candidate $ExpectedCandidate; acceptance identifies '$candidateName'"}
if([int]$synthesisAcceptance.source_files -ne 18 -or @($upstreamManifest.files).Count -ne 18){throw 'Candidate M requires the accepted 18-file source snapshot'}
if($synthesisAcceptance.functional_RTL_TB_vectors_match -ne $true -or
   $snapshotCheck.status -ne 'frozen_checked' -or
   $snapshotCheck.functional_RTL_TB_match -ne $true -or
   [int]$snapshotCheck.functional_sample0_mem_hashes_match -ne 10){
    throw 'Parent functional RTL/TB/vector snapshot check is not accepted'
}
if($synthesisAcceptance.status -notin @('ACCEPTED_SYNTH_NEGATIVE_SETUP','ACCEPTED_SYNTH_FOR_ROUTE')){
    throw "Unexpected parent synthesis status: $($synthesisAcceptance.status)"
}
if((Get-FileHash -LiteralPath $checkpoint -Algorithm SHA256).Hash -ne $synthesisAcceptance.checkpoint_sha256){
    throw 'Synthesized DCP hash differs from parent_synthesis_acceptance.json'
}
$coreEntry=@($upstreamManifest.files | Where-Object {$_.path -eq 'rtl/cnn/d4_fullnet_top.sv'})
if($coreEntry.Count -ne 1 -or $coreEntry[0].sha256 -ne $ExpectedCoreSha256){
    throw "Candidate $ExpectedCandidate core RTL identity does not match the root-selected SHA $ExpectedCoreSha256"
}
$functionalPaths=@('rtl/cnn/d4_fullnet_clocking.sv','rtl/cnn/d4_fullnet_top.sv','rtl/cnn/d4_fullnet_impl_top.sv','sim/tb_d4_fullnet_packed.sv')
foreach($path in $functionalPaths){
    if(@($upstreamManifest.files | Where-Object {$_.path -eq $path}).Count -ne 1){throw "Missing exact functional RTL/TB identity: $path"}
}
$xdcEntry=@($upstreamManifest.files | Where-Object {$_.path -eq 'constraints/d4_fullnet_8ns.xdc'})
if($xdcEntry.Count -ne 1){throw 'Expected exactly one upstream constraints/d4_fullnet_8ns.xdc manifest entry'}
$verifiedInputs=@()
foreach($entry in $upstreamManifest.files){
    $relative=$entry.path.Replace('/','\')
    $snapshotPath=Join-Path $sourceSnapshot $relative
    if(!(Test-Path -LiteralPath $snapshotPath -PathType Leaf)){throw "Missing immutable source snapshot file: $snapshotPath"}
    $actual=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
    if($actual -ne $entry.sha256){throw "Upstream source hash mismatch for $($entry.path): expected=$($entry.sha256) actual=$actual"}
    $verifiedInputs += [pscustomobject]@{path=$entry.path;upstream_sha256=$entry.sha256;snapshot_path=$snapshotPath}
}
$correctedXdcHash=(Get-FileHash -LiteralPath $correctedXdc -Algorithm SHA256).Hash
$out=Join-Path $root "build/reports/d4_fullnet_route_$RunId"
if(Test-Path -LiteralPath $out){throw "Refusing existing output: $out"}
New-Item -ItemType Directory -Path $out | Out-Null
Copy-Item -LiteralPath $sourceManifestPath -Destination (Join-Path $out 'upstream_source_manifest.json')
Copy-Item -LiteralPath $acceptancePath -Destination (Join-Path $out 'parent_synthesis_acceptance.json')
$packageRoot=Join-Path $out 'sources'
foreach($entry in $verifiedInputs){
    $relative=$entry.path.Replace('/','\')
    $destination=Join-Path $packageRoot $relative
    $destinationDirectory=Split-Path -Parent $destination
    New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
    if($entry.path -eq 'constraints/d4_fullnet_8ns.xdc'){
        Copy-Item -LiteralPath $correctedXdc -Destination $destination
        $provenance='root_corrected_constraint_overlay_source'
        $finalHash=$correctedXdcHash
    } else {
        Copy-Item -LiteralPath $entry.snapshot_path -Destination $destination
        $provenance='immutable_synthesis_source_snapshot'
        $finalHash=$entry.upstream_sha256
    }
    $copiedHash=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
    if($copiedHash -ne $finalHash){throw "Packaged source hash mismatch for $($entry.path)"}
    $upstreamSnapshotPath=$entry.snapshot_path
    $entry | Add-Member -NotePropertyName final_sha256 -NotePropertyValue $finalHash
    $entry | Add-Member -NotePropertyName provenance -NotePropertyValue $provenance
    $entry | Add-Member -NotePropertyName unchanged_from_synthesis -NotePropertyValue ($finalHash -eq $entry.upstream_sha256)
    $entry | Add-Member -NotePropertyName upstream_snapshot_path -NotePropertyValue $upstreamSnapshotPath
    $entry | Add-Member -NotePropertyName snapshot_path -NotePropertyValue ("sources/$($entry.path)") -Force
    $entry | Add-Member -NotePropertyName final_snapshot_path -NotePropertyValue ("sources/$($entry.path)")
}
$finalSourceManifest=@{
    stage='route_reproducibility_source_bundle'
    candidate=$candidateName
    source_root='sources/'
    upstream_source_manifest='upstream_source_manifest.json'
    upstream_source_manifest_sha256=(Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash
    source_manifest_sha256=(Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash
    source_files=$verifiedInputs
    constraints=@{
        path='sources/constraints/d4_fullnet_8ns.xdc'
        synth_xdc_sha256=$xdcEntry[0].sha256
        corrected_xdc_sha256=$correctedXdcHash
        overlay=@{command='set_input_jitter [get_clocks physical_clk] 0.050';clock='physical_clk';input_jitter_ns=0.050;application='after open_checkpoint';verification='get_property INPUT_JITTER physical_clk == 0.050'}
        other_constraints='No timing constraints were reset or relaxed; 8 ns primary, 0.2 ns uncertainty, input/output delays and 5 pF output load are retained.'
    }
} 
$finalSourceManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'final_source_manifest.json') -Encoding utf8
$tcl=Join-Path $out 'route_flow.tcl'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'vivado_d4_route_checkpoint.tcl') -Destination $tcl
$runnerHash=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$routeManifest=@{
    stage='route_from_immutable_synth_checkpoint'
    candidate=$candidateName
    checkpoint=$checkpoint
    checkpoint_sha256=(Get-FileHash -LiteralPath $checkpoint -Algorithm SHA256).Hash
    upstream_source_manifest='upstream_source_manifest.json'
    upstream_source_manifest_sha256=(Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash
    synthesis_acceptance='parent_synthesis_acceptance.json'
    synthesis_acceptance_sha256=(Get-FileHash -LiteralPath $acceptancePath -Algorithm SHA256).Hash
    source_snapshot=$sourceSnapshot
    source_snapshot_files=$verifiedInputs.Count
    runner_script_sha256=$runnerHash
    route_tcl='route_flow.tcl'
    route_tcl_sha256=(Get-FileHash -LiteralPath $tcl -Algorithm SHA256).Hash
    final_source_manifest='final_source_manifest.json'
    final_source_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $out 'final_source_manifest.json') -Algorithm SHA256).Hash
    corrected_xdc='sources/constraints/d4_fullnet_8ns.xdc'
    corrected_xdc_sha256=$correctedXdcHash
    synth_xdc_sha256=$xdcEntry[0].sha256
    jitter_overlay='set_input_jitter [get_clocks physical_clk] 0.050 after open_checkpoint; assert INPUT_JITTER=0.050 ns'
    clock_period_ns=8.0
    physical_clock='physical_clk'
    tool=$Vivado
    selection=@{opt_design='default';place_design='Explore';phys_opt_design='Explore';route_design='Explore'}
} 
$routeManifest |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'route_manifest.json') -Encoding utf8
$previous=$ErrorActionPreference
$ErrorActionPreference='Continue'
try {
    & $Vivado -mode batch -notrace -source $tcl -log (Join-Path $out 'vivado.log') `
        -journal (Join-Path $out 'vivado.jou') -tclargs $checkpoint $out *> (Join-Path $out 'console.log')
    $code=$LASTEXITCODE
} finally {$ErrorActionPreference=$previous}
if($code -ne 0){throw "Route failed exit=$code; $out/console.log"}
$routedCheckpoint=Join-Path $out 'routed.dcp'
if(!(Test-Path -LiteralPath $routedCheckpoint)){throw "Missing routed checkpoint in $out"}
$routedHash=(Get-FileHash -LiteralPath $routedCheckpoint -Algorithm SHA256).Hash
$optionalErrorPath=Join-Path $out 'optional_report_errors.txt'
$optionalErrorLines=@()
if(Test-Path -LiteralPath $optionalErrorPath){
    $optionalErrorLines=@(Get-Content -LiteralPath $optionalErrorPath | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
}
$artifactHashes=@{
    status='ROUTE_COMPLETED_PENDING_REVIEW'
    candidate=$candidateName
    input_synth_dcp=$checkpoint
    input_synth_dcp_sha256=(Get-FileHash -LiteralPath $checkpoint -Algorithm SHA256).Hash
    output_routed_dcp='routed.dcp'
    output_routed_dcp_sha256=$routedHash
    upstream_source_manifest='upstream_source_manifest.json'
    upstream_source_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $out 'upstream_source_manifest.json') -Algorithm SHA256).Hash
    final_source_manifest='final_source_manifest.json'
    final_source_manifest_sha256=(Get-FileHash -LiteralPath (Join-Path $out 'final_source_manifest.json') -Algorithm SHA256).Hash
    route_tcl='route_flow.tcl'
    route_tcl_sha256=(Get-FileHash -LiteralPath $tcl -Algorithm SHA256).Hash
    runner_script_sha256=$runnerHash
    source_file_count=$verifiedInputs.Count
    route_selection=@{opt_design='default';place_design='Explore';phys_opt_design='Explore';route_design='Explore'}
    optional_report_error_count=$optionalErrorLines.Count
    optional_report_errors=$optionalErrorLines
}
$artifactHashes | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'route_artifact_hashes.json') -Encoding utf8
Write-Output "ROUTE_COMPLETED reports=$out (inspect route/timing/power before acceptance)"
