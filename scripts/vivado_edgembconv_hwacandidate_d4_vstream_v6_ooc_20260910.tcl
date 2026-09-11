# Standalone XC7Z020 OOC screen for the D4 vstream v6 mb16_down candidate.
# The caller supplies a fresh output directory as argv[0] and an optional
# stage selector (synth_only or route) as argv[1].
set root [file normalize [file join [file dirname [info script]] ..]]
if {[llength $argv] < 1} {
    error "usage: vivado ... -source $::argv0 -tclargs <fresh-output-dir> ?synth_only|route?"
}
set out [file normalize [lindex $argv 0]]
set stage route
if {[llength $argv] >= 2} {
    set stage [lindex $argv 1]
}
if {$stage ne "synth_only" && $stage ne "route"} {
    error "invalid stage '$stage'; expected synth_only or route"
}
file mkdir $out

set part xc7z020clg400-1
set requested_threads 8
set_param general.maxThreads $requested_threads
set actual_threads [get_param general.maxThreads]
if {$actual_threads != $requested_threads} {
    error "general.maxThreads did not take effect: requested=$requested_threads actual=$actual_threads"
}

set rtl_files {
    rtl/cnn/edgembconv_hwacandidate_d4_dsp_pool.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_elastic_rq_pool.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_elastic_rq_pool_regin.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_banked_storage.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_common_bank.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_fetch_pair.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_raw_fifo.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_dw_req_adapter.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v2_datapath.v
    rtl/cnn/edgembconv_hwacandidate_d4_dw16_stream_tile.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_scheduler.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_mb16_controller.v
    rtl/cnn/edgembconv_hwacandidate_d4_vstream_v6_ooc_wrapper.v
}
set constraint_file constraints/edgembconv_hwacandidate_d4_vstream_v6_ooc_8ns.xdc

set settings [open [file join $out run_settings.txt] w]
puts $settings "format=v6-standalone-ooc-v1"
puts $settings "stage=$stage"
puts $settings "tool=Vivado 2025.2"
puts $settings "part=$part"
puts $settings "clock_period_ns=8.000"
puts $settings "requested_maxThreads=$requested_threads"
puts $settings "actual_maxThreads=$actual_threads"
puts $settings "top=edgembconv_hwacandidate_d4_vstream_v6_ooc_wrapper"
puts $settings "constraint_file=$constraint_file"
puts $settings "rtl_count=[llength $rtl_files]"
foreach f $rtl_files { puts $settings "rtl=$f" }
close $settings

foreach f $rtl_files {
    set path [file join $root $f]
    if {![file exists $path]} { error "missing RTL source: $path" }
    read_verilog -sv $path
}
set xdc_path [file join $root $constraint_file]
if {![file exists $xdc_path]} { error "missing constraint file: $xdc_path" }

puts "V6_OOC_SYNTH_START out=$out part=$part clock_ns=8.000 maxThreads=$actual_threads"
synth_design -top edgembconv_hwacandidate_d4_vstream_v6_ooc_wrapper \
    -part $part -flatten_hierarchy rebuilt -mode out_of_context \
    -directive RuntimeOptimized
read_xdc $xdc_path

report_utilization -file [file join $out utilization_synth.txt]
report_utilization -hierarchical -file [file join $out utilization_hierarchical_synth.txt]
report_timing_summary -delay_type min_max -max_paths 100 -report_unconstrained \
    -file [file join $out timing_summary_synth.txt]
report_drc -file [file join $out drc_synth.txt]
set synth_dsp [get_cells -hierarchical -quiet -filter {REF_NAME == DSP48E1}]
set synth_bram [get_cells -hierarchical -quiet -filter {REF_NAME =~ RAMB*}]
set synth_banked_bram [get_cells -hierarchical -quiet \
    -filter {REF_NAME =~ RAMB* && NAME =~ *u_v6_banked_storage*}]
set synth_common_bram [get_cells -hierarchical -quiet \
    -filter {REF_NAME =~ RAMB* && NAME =~ *u_v6_common_bank*}]
set synth_lut [get_cells -hierarchical -quiet -filter {REF_NAME =~ LUT*}]
set synth_ff [get_cells -hierarchical -quiet -filter {REF_NAME =~ FD*}]
set synth_cells [get_cells -hierarchical -quiet]
set sf [open [file join $out synth_cell_counts.txt] w]
puts $sf "synth_cells=[llength $synth_cells]"
puts $sf "synth_lut_cells=[llength $synth_lut]"
puts $sf "synth_ff_cells=[llength $synth_ff]"
puts $sf "synth_dsp48e1_cells=[llength $synth_dsp]"
puts $sf "synth_ramb_cells=[llength $synth_bram]"
puts $sf "synth_banked_storage_ramb_cells=[llength $synth_banked_bram]"
puts $sf "synth_common_bank_ramb_cells=[llength $synth_common_bram]"
close $sf
write_checkpoint -force [file join $out v6_ooc_post_synth.dcp]
puts "V6_OOC_SYNTH_DONE out=$out dsp=[llength $synth_dsp] bram=[llength $synth_bram]"

if {$stage eq "synth_only"} {
    exit
}

puts "V6_OOC_ROUTE_START out=$out"
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore

report_timing_summary -delay_type min_max -max_paths 200 -report_unconstrained \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_utilization -hierarchical -file [file join $out utilization_hierarchical_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_design_analysis -congestion -file [file join $out congestion_post_route.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out v6_ooc_post_route.dcp]

set route_status UNAVAILABLE
catch {set route_status [get_property ROUTE_STATUS [current_design]]}
set route_report_fh [open [file join $out route_status_post_route.txt] r]
set route_report_text [read $route_report_fh]
close $route_report_fh
set route_complete [expr {[regexp -nocase {fully routed} $route_report_text] &&
                          ![regexp -nocase {unrouted\s+nets\s*:\s*[1-9]} $route_report_text]}]
set route_settings [open [file join $out route_metrics.txt] w]
puts $route_settings "route_status=$route_status"
puts $route_settings "route_complete=$route_complete"
puts $route_settings "dsp48e1_cells=[llength [get_cells -hierarchical -quiet -filter {REF_NAME == DSP48E1}]]"
puts $route_settings "ramb_cells=[llength [get_cells -hierarchical -quiet -filter {REF_NAME =~ RAMB*}]]"
puts $route_settings "lut_cells=[llength [get_cells -hierarchical -quiet -filter {REF_NAME =~ LUT*}]]"
puts $route_settings "ff_cells=[llength [get_cells -hierarchical -quiet -filter {REF_NAME =~ FD*}]]"
close $route_settings
puts "V6_OOC_ROUTE_DONE out=$out"
exit
