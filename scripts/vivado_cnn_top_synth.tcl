set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ".."]]

if {[llength $argv] >= 2} {
    set top_name [lindex $argv 0]
    set part_name [lindex $argv 1]
} elseif {[llength $argv] == 1 && [string length [lindex $argv 0]] > 0} {
    set top_name "cnn_top"
    set part_name [lindex $argv 0]
} elseif {[info exists ::env(VIVADO_PART)] && [string length $::env(VIVADO_PART)] > 0} {
    set top_name "cnn_top"
    set part_name $::env(VIVADO_PART)
} else {
    set top_name "cnn_top"
    set part_name "xck26-sfvc784-2LV-c"
}

set out_dir [file join $project_root "build" "reports" "vivado_$top_name"]
file mkdir $out_dir

set_param general.maxThreads 4

if {$top_name eq "cnn_top"} {
    set report_md [file join $project_root "docs" "synthesis_vivado_initial.md"]
    set build_md [file join $project_root "build" "reports" "synthesis_vivado_initial.md"]
} else {
    set report_md [file join $project_root "docs" "synthesis_vivado_$top_name.md"]
    set build_md [file join $project_root "build" "reports" "synthesis_vivado_$top_name.md"]
}

proc write_failure_report {report_md build_md top_name part_name msg} {
    set now [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]
    set fh [open $report_md "w"]
    puts $fh "# Vivado Initial Synthesis Report"
    puts $fh ""
    puts $fh "- Date: $now"
    puts $fh "- Tool: Vivado batch synthesis"
    puts $fh "- Top module: `$top_name`"
    puts $fh "- Part: `$part_name`"
    puts $fh "- Status: FAILED"
    puts $fh ""
    puts $fh "## Error"
    puts $fh ""
    puts $fh "```text"
    puts $fh $msg
    puts $fh "```"
    close $fh
    file copy -force $report_md $build_md
}

set rtl_files [list \
    "rtl/common/round_shift.v" \
    "rtl/common/saturate_int8.v" \
    "rtl/cnn/requant_activation_unit.v" \
    "rtl/cnn/systolic_pe.v" \
    "rtl/cnn/pw_systolic_array_8x8.v" \
    "rtl/cnn/dw_line_buffer.v" \
    "rtl/cnn/dw_window_generator.v" \
    "rtl/cnn/dw_mac_lanes.v" \
    "rtl/cnn/dw_tile_buffer.v" \
    "rtl/cnn/dw_tile_fusion_engine.v" \
    "rtl/cnn/ds_block_tile_engine.v" \
    "rtl/cnn/conv3x3_stem_engine.v" \
    "rtl/cnn/gap_unit.v" \
    "rtl/cnn/fc_unit.v" \
    "rtl/cnn/tile_scheduler.v" \
    "rtl/cnn/feature_sram_bank.v" \
    "rtl/cnn/feature_sram_pingpong.v" \
    "rtl/cnn/status_counter.v" \
    "rtl/cnn/descriptor_fetch.v" \
    "rtl/cnn/cnn_layer_runner.v" \
    "rtl/cnn/cnn_top_ctrl.v" \
    "rtl/cnn/cnn_top.v" \
]

foreach f $rtl_files {
    read_verilog -sv [file join $project_root $f]
}

set synth_result [catch {
    synth_design -top $top_name -part $part_name -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
} synth_msg]

if {$synth_result != 0} {
    write_failure_report $report_md $build_md $top_name $part_name $synth_msg
    error $synth_msg
}

if {[llength [get_ports -quiet clk]] > 0} {
    create_clock -period 10.000 -name clk [get_ports clk]
}

report_utilization -file [file join $out_dir "utilization.txt"]
report_utilization -hierarchical -file [file join $out_dir "utilization_hierarchical.txt"]
set timing_status "PASSED"
set timing_msg ""
if {[catch {report_timing_summary -file [file join $out_dir "timing_summary.txt"]} timing_msg]} {
    set timing_status "FAILED: $timing_msg"
}
set clock_status "PASSED"
set clock_msg ""
if {[catch {report_clock_utilization -file [file join $out_dir "clock_utilization.txt"]} clock_msg]} {
    set clock_status "FAILED: $clock_msg"
}
set checkpoint_status "PASSED"
set checkpoint_msg ""
if {[catch {write_checkpoint -force [file join $out_dir "${top_name}_synth.dcp"]} checkpoint_msg]} {
    set checkpoint_status "FAILED: $checkpoint_msg"
}

set version_text [version -short]
set now [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]
set wns "unknown"
set tns "unknown"
set whs "unknown"
set ths "unknown"
if {$timing_status eq "PASSED" && [llength [get_timing_paths -quiet -max_paths 1 -slack_lesser_than 1000000]] > 0} {
    set p [lindex [get_timing_paths -quiet -max_paths 1] 0]
    set wns [get_property SLACK $p]
}
set lut_count [llength [get_cells -hier -filter {REF_NAME =~ LUT*}]]
set ff_count [llength [get_cells -hier -filter {REF_NAME =~ FD*}]]
set bram_count [expr {[llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]] + [llength [get_cells -hier -filter {REF_NAME =~ FIFO*}]]}]
set dsp_count [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]

set fh [open $report_md "w"]
puts $fh "# Vivado Initial Synthesis Report"
puts $fh ""
puts $fh "- Date: $now"
puts $fh "- Tool: Vivado $version_text"
puts $fh "- Top module: `$top_name`"
puts $fh "- Part: `$part_name`"
puts $fh "- Clock constraint: 10.000 ns"
puts $fh "- Status: PASSED"
puts $fh "- Timing summary: $timing_status"
puts $fh "- Clock utilization report: $clock_status"
puts $fh "- Checkpoint write: $checkpoint_status"
puts $fh ""
puts $fh "## Quick Counts"
puts $fh ""
puts $fh "| Metric | Value |"
puts $fh "| --- | ---: |"
puts $fh "| LUT primitive cells | $lut_count |"
puts $fh "| FF/latch primitive cells | $ff_count |"
puts $fh "| BRAM-like primitive cells | $bram_count |"
puts $fh "| DSP primitive cells | $dsp_count |"
puts $fh "| Worst observed max-path slack | $wns ns |"
puts $fh ""
puts $fh "## Generated Reports"
puts $fh ""
puts $fh "- `build/reports/vivado_$top_name/utilization.txt`"
puts $fh "- `build/reports/vivado_$top_name/utilization_hierarchical.txt`"
puts $fh "- `build/reports/vivado_$top_name/timing_summary.txt`"
puts $fh "- `build/reports/vivado_$top_name/clock_utilization.txt`"
puts $fh "- `build/reports/vivado_$top_name/${top_name}_synth.dcp` if checkpoint write passed"
puts $fh ""
puts $fh "## Notes"
puts $fh ""
puts $fh "This is an initial synthesis-only result. It is not post-place-and-route timing and does not include board-level IO constraints."
close $fh

file copy -force $report_md $build_md
