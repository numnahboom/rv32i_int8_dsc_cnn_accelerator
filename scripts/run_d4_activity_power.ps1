param(
    [Parameter(Mandatory=$true)][string]$Vcd,
    [Parameter(Mandatory=$true)][string]$Dcp,
    [string]$SimulationLog,
    [string]$Vivado='D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat',
    [string]$Python='python',
    [string]$RunId=(Get-Date -Format 'yyyyMMdd_HHmmss'),
    [string]$OutDir,
    [string]$VcdRoot='TOP.tb_d4_fullnet.dut',
    [string]$TargetRoot='d4_fullnet_impl_top.u_core',
    [Nullable[int]]$DurationTicks,
    [string]$SourceRoot,
    [string]$HierarchyBindingTsv
)

$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if($SourceRoot){
    $sourceRootCandidate=if([IO.Path]::IsPathRooted($SourceRoot)){$SourceRoot}else{Join-Path $root $SourceRoot}
    $sourceRootPath=(Resolve-Path -LiteralPath $sourceRootCandidate).Path
}else{
    $sourceRootPath=$root
}
$vcdPath=(Resolve-Path -LiteralPath $Vcd).Path
$dcpPath=(Resolve-Path -LiteralPath $Dcp).Path
$vivadoPath=(Resolve-Path -LiteralPath $Vivado).Path
$tclPath=(Resolve-Path (Join-Path $PSScriptRoot 'vivado_d4_activity_power.tcl')).Path
$converterPath=(Resolve-Path (Join-Path $root 'python/d4_activity_power.py')).Path
$wrapperPath=(Resolve-Path -LiteralPath $PSCommandPath).Path
$rtlTopPath=(Resolve-Path (Join-Path $sourceRootPath 'rtl/cnn/d4_fullnet_top.sv')).Path
$rtlImplTopPath=(Resolve-Path (Join-Path $sourceRootPath 'rtl/cnn/d4_fullnet_impl_top.sv')).Path
$rtlClockingPath=Join-Path $sourceRootPath 'rtl/cnn/d4_fullnet_clocking.sv'
$sourceManifestPath=Join-Path (Split-Path $sourceRootPath -Parent) 'source_manifest.json'
$constraintPath=(Resolve-Path (Join-Path $sourceRootPath 'constraints/d4_fullnet_8ns.xdc')).Path
$simLogPath=$null
if($SimulationLog){$simLogPath=(Resolve-Path -LiteralPath $SimulationLog).Path}
$hierarchyBindingPath=$null
$bindingProvenance=$null
if($HierarchyBindingTsv){
    $bindingCandidate=if([IO.Path]::IsPathRooted($HierarchyBindingTsv)){$HierarchyBindingTsv}else{Join-Path $root $HierarchyBindingTsv}
    $hierarchyBindingPath=(Resolve-Path -LiteralPath $bindingCandidate).Path
    if(!(Test-Path -LiteralPath $hierarchyBindingPath -PathType Leaf)){throw "Hierarchy binding input is not a file: $hierarchyBindingPath"}

    $bindingEvidenceRoot=Join-Path $root 'build/reports/d4_fullnet_synth_rq_valid_enable_20261018'
    $bindingHierarchyPath=(Resolve-Path -LiteralPath (Join-Path $bindingEvidenceRoot 'hierarchy_synth.tsv')).Path
    $bindingManifestPath=(Resolve-Path -LiteralPath (Join-Path $bindingEvidenceRoot 'source_manifest.json')).Path
    $bindingCorePath=(Resolve-Path -LiteralPath (Join-Path $bindingEvidenceRoot 'sources/rtl/cnn/d4_fullnet_top.sv')).Path
    $bindingCheckpointPath=(Resolve-Path -LiteralPath (Join-Path $bindingEvidenceRoot 'synth.dcp')).Path
    $bindingTableHash=(Get-FileHash -LiteralPath $hierarchyBindingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $bindingHierarchyHash=(Get-FileHash -LiteralPath $bindingHierarchyPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $bindingManifestHash=(Get-FileHash -LiteralPath $bindingManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $bindingCoreHash=(Get-FileHash -LiteralPath $bindingCorePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $bindingCheckpointHash=(Get-FileHash -LiteralPath $bindingCheckpointPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHierarchyHash='510b1c68b77c7812d47637fa2f13b96c74a927747dedb26a12484c663d3a83d8'
    $expectedManifestHash='61d0d2b776fc62b6f3185ea9f023cb9427a3f761072ac7cb84794e42b48d91e7'
    $expectedCoreHash='706cf563ca1f838a337fda154341f1af33c6fdef79a071320ac3259d2f21d529'
    $expectedCheckpointHash='aebbe62c935aacd179237cf39083fcff9dba69ab24194cb7c47f456d1897f88b'
    $bindingManifest=Get-Content -LiteralPath $bindingManifestPath -Raw | ConvertFrom-Json
    $frozenCoreEntry=@($bindingManifest.files | Where-Object {$_.path -eq 'rtl/cnn/d4_fullnet_top.sv'})
    if($bindingHierarchyHash -ne $expectedHierarchyHash -or
       $bindingManifestHash -ne $expectedManifestHash -or
       $bindingCoreHash -ne $expectedCoreHash -or
       $bindingCheckpointHash -ne $expectedCheckpointHash -or
       $frozenCoreEntry.Count -ne 1 -or
       $frozenCoreEntry[0].sha256.ToLowerInvariant() -ne $bindingCoreHash){
        throw 'Explicit hierarchy binding evidence hashes do not match the frozen L2 hierarchy/core package.'
    }
    $bindingProvenance=[ordered]@{
        status='explicit_enumerated_l2_binding'
        binding_table=[ordered]@{path=$hierarchyBindingPath;sha256=$bindingTableHash}
        observed_hierarchy=[ordered]@{path=$bindingHierarchyPath;sha256=$bindingHierarchyHash}
        frozen_core=[ordered]@{path=$bindingCorePath;sha256=$bindingCoreHash}
        frozen_source_manifest=[ordered]@{path=$bindingManifestPath;sha256=$bindingManifestHash}
        observed_synth_checkpoint=[ordered]@{path=$bindingCheckpointPath;sha256=$bindingCheckpointHash}
        runtime_validation='each supplied physical cell NAME, ORIG_REF_NAME, and PARENT is checked against the current checkpoint in Vivado Tcl'
        native_final_checkpoint_validation='required later; not established by this bounded offline tooling check'
    }
}

if(!$OutDir){$OutDir="build/reports/d4_fullnet_activity_$RunId"}
if([IO.Path]::IsPathRooted($OutDir)){$outPath=[IO.Path]::GetFullPath($OutDir)}
else{$outPath=[IO.Path]::GetFullPath((Join-Path $root $OutDir))}
if(Test-Path -LiteralPath $outPath){throw "Refusing existing output directory: $outPath"}
New-Item -ItemType Directory -Path $outPath | Out-Null

$saifPath=Join-Path $outPath 'activity.saif'
$metadataPath=Join-Path $outPath 'activity_metadata.json'
$conversionLog=Join-Path $outPath 'converter.log'
$vivadoLog=Join-Path $outPath 'vivado.log'
$vivadoJournal=Join-Path $outPath 'vivado.jou'
$vivadoConsole=Join-Path $outPath 'vivado_console.log'

$converterArgs=@(
    $converterPath,'--vcd',$vcdPath,'--saif',$saifPath,'--metadata',$metadataPath,
    '--vcd-root',$VcdRoot,'--target-root',$TargetRoot
)
if($null -ne $DurationTicks){$converterArgs+=@('--duration-ticks',[string]$DurationTicks.Value)}
& $Python @converterArgs *> $conversionLog
$conversionCode=$LASTEXITCODE
if($conversionCode -ne 0){
    Get-Content -LiteralPath $conversionLog -Tail 40
    throw "VCD-to-SAIF conversion failed with exit=$conversionCode; see $conversionLog"
}

$metadata=Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$inputHashes=[ordered]@{
    routed_checkpoint=@{path=$dcpPath;sha256=(Get-FileHash -LiteralPath $dcpPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    source_vcd=@{path=$vcdPath;sha256=$metadata.source_vcd_sha256}
    generated_saif=@{path=$saifPath;sha256=$metadata.saif_sha256}
    converter_source=@{path=$converterPath;sha256=$metadata.converter_source_sha256}
    vivado_tcl=@{path=$tclPath;sha256=(Get-FileHash -LiteralPath $tclPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    wrapper_source=@{path=$wrapperPath;sha256=(Get-FileHash -LiteralPath $wrapperPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    rtl_top_source=@{path=$rtlTopPath;sha256=(Get-FileHash -LiteralPath $rtlTopPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    implementation_top_source=@{path=$rtlImplTopPath;sha256=(Get-FileHash -LiteralPath $rtlImplTopPath -Algorithm SHA256).Hash.ToLowerInvariant()}
    implementation_constraints=@{path=$constraintPath;sha256=(Get-FileHash -LiteralPath $constraintPath -Algorithm SHA256).Hash.ToLowerInvariant()}
}
if($bindingProvenance){
    $inputHashes.hierarchy_binding_table=$bindingProvenance.binding_table
    $inputHashes.binding_observed_hierarchy=$bindingProvenance.observed_hierarchy
    $inputHashes.binding_frozen_core=$bindingProvenance.frozen_core
    $inputHashes.binding_frozen_source_manifest=$bindingProvenance.frozen_source_manifest
    $inputHashes.binding_observed_synth_checkpoint=$bindingProvenance.observed_synth_checkpoint
}
if(Test-Path -LiteralPath $rtlClockingPath -PathType Leaf){
    $inputHashes.clocking_source=@{path=$rtlClockingPath;status='hashed';sha256=(Get-FileHash -LiteralPath $rtlClockingPath -Algorithm SHA256).Hash.ToLowerInvariant()}
}else{
    $inputHashes.clocking_source=@{path=$rtlClockingPath;status='not_applicable_missing';sha256=$null}
}
if(Test-Path -LiteralPath $sourceManifestPath -PathType Leaf){
    $inputHashes.source_manifest=@{path=$sourceManifestPath;sha256=(Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()}
}
if($simLogPath){$inputHashes.simulation_log=@{path=$simLogPath;sha256=(Get-FileHash -LiteralPath $simLogPath -Algorithm SHA256).Hash.ToLowerInvariant()}}
$metadata | Add-Member -Force -NotePropertyName input_hashes -NotePropertyValue $inputHashes
if($bindingProvenance){
    $metadata | Add-Member -Force -NotePropertyName hierarchy_binding_provenance -NotePropertyValue $bindingProvenance
}
$metadata | Add-Member -Force -NotePropertyName source_root -NotePropertyValue $sourceRootPath
$metadata | Add-Member -Force -NotePropertyName checkpoint_source_relationship -NotePropertyValue 'unverified unless independently checked against an upstream manifest'
$saifStripPath=($TargetRoot -split '\.')[0]
$metadata | Add-Member -Force -NotePropertyName vivado_run -NotePropertyValue @{
    status='running'
    started_at_utc=[DateTime]::UtcNow.ToString('o')
    exit_code=$null
    vivado_executable=$vivadoPath
    checkpoint=$dcpPath
    output_directory=$outPath
    simulation_log=$simLogPath
    scope_mapping="${VcdRoot} -> ${TargetRoot}"
    saif_mapping="read_saif -strip_path $saifStripPath"
}
$metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding utf8

$runCode=1
try {
    $previousErrorActionPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        $vivadoArgs=@('-mode','batch','-notrace','-source',$tclPath,
                      '-log',$vivadoLog,'-journal',$vivadoJournal,'-tclargs',
                      $dcpPath,$saifPath,$outPath,$TargetRoot)
        if($hierarchyBindingPath){$vivadoArgs+=$hierarchyBindingPath}
        & $vivadoPath @vivadoArgs *> $vivadoConsole
        $runCode=$LASTEXITCODE
    } finally {
        $ErrorActionPreference=$previousErrorActionPreference
    }
} finally {
    $metadata=Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    $metadata.vivado_run.status=if($runCode -eq 0){'completed'}else{'failed'}
    $metadata.vivado_run.exit_code=$runCode
    $metadata.vivado_run | Add-Member -Force -NotePropertyName finished_at_utc -NotePropertyValue ([DateTime]::UtcNow.ToString('o'))
    $outputHashes=[ordered]@{}
    foreach($name in @('power_after_saif_annotation.txt','switching_activity_after_saif.txt',
                       'saif_annotation_messages.txt','fd_q_alias_annotation_messages.txt',
                       'fd_q_alias.saif','fd_q_alias_points.tsv','fd_q_alias_summary.txt',
                       'fd_q_hierarchy_binding_validation.tsv',
                       'top_level_port_activity_assignments.tsv',
                       'activity_annotation_scope.txt','route_status_input_checkpoint.txt',
                       'vivado.log')){
        $path=Join-Path $outPath $name
        if(Test-Path -LiteralPath $path){
            $outputHashes[$name]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $metadata | Add-Member -Force -NotePropertyName report_sha256 -NotePropertyValue $outputHashes
    $metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding utf8
}

$requiredReports=@('power_after_saif_annotation.txt','switching_activity_after_saif.txt',
                   'saif_annotation_messages.txt','activity_annotation_scope.txt',
                   'fd_q_alias_annotation_messages.txt','fd_q_alias.saif',
                   'fd_q_alias_points.tsv','fd_q_alias_summary.txt',
                   'top_level_port_activity_assignments.tsv',
                   'route_status_input_checkpoint.txt','vivado.log')
$missing=@($requiredReports | Where-Object {!(Test-Path -LiteralPath (Join-Path $outPath $_))})
if($hierarchyBindingPath -and !(Test-Path -LiteralPath (Join-Path $outPath 'fd_q_hierarchy_binding_validation.tsv'))){
    $missing+= 'fd_q_hierarchy_binding_validation.tsv'
}
if($runCode -ne 0){throw "Vivado annotation/power run failed with exit=$runCode; inspect $vivadoConsole and $vivadoLog"}
if($missing.Count){throw "Vivado completed but required evidence is missing: $($missing -join ', ')"}

$powerText=Get-Content -LiteralPath (Join-Path $outPath 'power_after_saif_annotation.txt') -Raw
$fieldValue={
    param([string]$Text,[string]$Label)
    $pattern='\|\s*'+[regex]::Escape($Label)+'\s*\|\s*([^|]+)\|'
    $match=[regex]::Match($Text,$pattern)
    if($match.Success){return $match.Groups[1].Value.Trim()}
    return $null
}
$matched=[regex]::Match($powerText,'\|\s*Design Nets Matched\s*\|\s*(\d+)%\s*\((\d+)/(\d+)\)')
$ioConfidence=[regex]::Match($powerText,'(?im)^\s*\|\s*I/O nodes activity\s*\|\s*([^|]+)\|\s*([^|]+)\|')
$matchedCount=$null; $designNetCount=$null; $matchedPercent=$null
if($matched.Success){
    $matchedPercent=[double]$matched.Groups[1].Value
    $matchedCount=[int]$matched.Groups[2].Value
    $designNetCount=[int]$matched.Groups[3].Value
}
$coverageExact=$null
if($null -ne $matchedCount -and $designNetCount -gt 0){
    $coverageExact=100.0*$matchedCount/$designNetCount
}
$vivadoLogText=Get-Content -LiteralPath (Join-Path $outPath 'vivado.log') -Raw
$nativeMatches=[regex]::Matches($vivadoLogText,'(?im)Design nets matched\s*=\s*(\d+)\s+of\s+(\d+)')
if($nativeMatches.Count -lt 2){
    throw "Vivado log does not contain separate original and FD-Q alias read_saif match counts; inspect $(Join-Path $outPath 'vivado.log')"
}
if(!$ioConfidence.Success){
    throw "Vivado power report does not contain I/O nodes activity confidence; inspect $(Join-Path $outPath 'power_after_saif_annotation.txt')"
}
$coverageRecord={
    param($Match)
    $count=[int]$Match.Groups[1].Value
    $total=[int]$Match.Groups[2].Value
    $exact=$null
    if($total -gt 0){$exact=100.0*$count/$total}
    [ordered]@{
        matched_nets=$count
        design_nets=$total
        coverage_percent_exact=$exact
        definition='Native Vivado read_saif matched nets for this individual SAIF import.'
    }
}
$originalReadSaif=& $coverageRecord $nativeMatches[0]
$aliasReadSaif=& $coverageRecord $nativeMatches[1]
$aliasSummary=@{}
foreach($line in Get-Content -LiteralPath (Join-Path $outPath 'fd_q_alias_summary.txt')){
    if($line -match '^([^=]+)=(.*)$'){$aliasSummary[$matches[1]]=$matches[2]}
}
$normalizedAliasSummary=[ordered]@{}
foreach($entry in $aliasSummary.GetEnumerator()){
    if($entry.Key -ne 'top_level_nonclock_ports_annotated_by_original_read_saif'){
        $normalizedAliasSummary[$entry.Key]=$entry.Value
    }
}
$normalizedAliasSummary['historical_port_field_correction']='Legacy candidate counts are not annotation evidence; this normalized summary reports candidates and explicit set_switching_activity commands separately.'
$portCandidateCount=$null
if($aliasSummary.Contains('exact_design_port_name_candidates')){
    $portCandidateCount=[int]$aliasSummary.exact_design_port_name_candidates
}elseif($aliasSummary.Contains('exact_top_level_port_candidates')){
    $portCandidateCount=[int]$aliasSummary.exact_top_level_port_candidates
}
$inputPortCandidateCount=$null
if($aliasSummary.Contains('top_level_nonclock_input_candidates')){
    $inputPortCandidateCount=[int]$aliasSummary.top_level_nonclock_input_candidates
}
$explicitPortAssignments=[int]$aliasSummary.explicit_set_switching_activity_assignments
$portAssignmentPath=Join-Path $outPath 'top_level_port_activity_assignments.tsv'
$portAssignmentRows=@(Import-Csv -LiteralPath $portAssignmentPath -Delimiter ([char]9))
$appliedPortRows=@($portAssignmentRows | Where-Object {$_.set_switching_activity -eq '1'})
if($appliedPortRows.Count -ne $explicitPortAssignments){
    throw 'Explicit port-activity assignment count does not match its TSV evidence.'
}
$aliasRows=@(Import-Csv -LiteralPath (Join-Path $outPath 'fd_q_alias_points.tsv') -Delimiter ([char]9))
$evidence=[ordered]@{
    schema_version=3
    generated_at_utc=[DateTime]::UtcNow.ToString('o')
    status='completed'
    input_hashes=$metadata.input_hashes
    read_saif_annotation=[ordered]@{
        original_saif=$originalReadSaif
        exact_fd_q_alias_saif=$aliasReadSaif
        counts_are_separate=$true
        combined_unique_coverage='not computed; overlap between imports is unknown'
    }
    top_level_port_activity=[ordered]@{
        exact_source_port_name_candidates=$portCandidateCount
        candidate_definition='Source SAIF PORT names with exact design-port-name matches; candidate count is not annotation evidence.'
        nonclock_input_candidates=$inputPortCandidateCount
        explicit_set_switching_activity_assignments=$explicitPortAssignments
        explicit_assignment_report='top_level_port_activity_assignments.tsv'
        explicit_assignment_status='Vivado Tcl issued assignments only for exact nonclock INPUT ports with fully known source statistics.'
        source_statistics='T0/T1/TX/TZ/TC from source SAIF; records are not changed.'
        signal_rate_formula_mtransitions_per_second='TC / duration_seconds / 1e6'
        static_probability_formula='T1 / DURATION for fully known residency'
        read_saif_port_annotation_verified=$false
    }
    fd_q_alias=[ordered]@{
        source_statistics='unchanged SAIF T0/T1/TX/TZ/TC'
        assignment_method='one separate read_saif of exact FD-Q physical NAME aliases'
        aliased_point_count=$aliasRows.Count
        summary=$normalizedAliasSummary
        alias_saif='fd_q_alias.saif'
        annotation_report='fd_q_alias_annotation_messages.txt'
        points_file='fd_q_alias_points.tsv'
    }
    power_estimate=[ordered]@{
        total_on_chip_w=& $fieldValue $powerText 'Total On-Chip Power (W)'
        dynamic_w=& $fieldValue $powerText 'Dynamic (W)'
        device_static_w=& $fieldValue $powerText 'Device Static (W)'
        confidence=& $fieldValue $powerText 'Confidence Level'
        io_nodes_activity=[ordered]@{
            confidence=$ioConfidence.Groups[1].Value.Trim()
            explanation=$ioConfidence.Groups[2].Value.Trim()
        }
        report_design_nets_matched=@{
            matched_nets=$matchedCount
            design_nets=$designNetCount
            vivado_display_percent=$matchedPercent
            coverage_percent_exact=$coverageExact
            definition='Design Nets Matched field in final power report; individual import counts are reported separately above.'
        }
        report='power_after_saif_annotation.txt'
    }
    limitations=@(
        'Vivado post-route estimate; not board-measured power.',
        'Unannotated activity may use Vivado vectorless propagation.',
        'Vivado confidence is reported as classified by the native power report, including its I/O activity confidence and explanation.',
        'Exact source port-name candidates are not counted as annotations; only recorded set_switching_activity commands are reported as explicit input assignments.'
    )
}
if($bindingProvenance){
    $evidence | Add-Member -Force -NotePropertyName hierarchy_binding_provenance -NotePropertyValue $bindingProvenance
}
$evidencePath=Join-Path $outPath 'evidence_summary.json'
$evidence | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $evidencePath -Encoding utf8
$metadata.report_sha256 | Add-Member -Force -NotePropertyName 'evidence_summary.json' -NotePropertyValue (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash.ToLowerInvariant()
$metadata | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $metadataPath -Encoding utf8
Write-Output "D4_ACTIVITY_POWER_COMPLETED reports=$outPath metadata=$metadataPath"
