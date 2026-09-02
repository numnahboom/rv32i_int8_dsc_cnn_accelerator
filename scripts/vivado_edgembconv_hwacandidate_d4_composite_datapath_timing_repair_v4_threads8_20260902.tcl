# Fresh XC7Z020 OOC screen for the independent D4 composite timing repair v4.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_edgembconv_hwacandidate_d4_composite_datapath_timing_repair_v4_threads8_20260902]]
file mkdir $out
set part xc7z020clg400-1
set_param general.maxThreads 8
read_verilog -sv [file join $root rtl cnn edgembconv_hwacandidate_d4_dsp_pool.v]
read_verilog -sv [file join $root rtl cnn edgembconv_hwacandidate_d4_composite_datapath.v]
synth_design -top edgembconv_hwacandidate_d4_composite_datapath -part $part -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
report_utilization -hierarchical -file [file join $out utilization_post_synth.txt]
opt_design
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
report_timing_summary -delay_type min_max -max_paths 200 -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -hierarchical -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out edgembconv_hwacandidate_d4_composite_datapath_timing_repair_v4_post_route.dcp]
set fh [open [file join $out run_settings.txt] w]
puts $fh "variant=edgembconv_hwacandidate_d4_composite_datapath_timing_repair_v4"
puts $fh "part=$part"
puts $fh "clock_ns=8.000"
puts $fh "general.maxThreads=[get_param general.maxThreads]"
set dsp_cells [get_cells -hier -filter {REF_NAME == DSP48E1}]
set pw_count 0
set pool_count 0
set dw_count 0
set addr_count 0
foreach cell $dsp_cells {
    set name [get_property NAME $cell]
    if {[string match "*u_pw112*" $name]} { incr pw_count }
    if {[string match "*u_pool*" $name]} { incr pool_count }
    if {[string match "*u_dw16*gen_d4_dw16_dsp*" $name]} { incr dw_count }
    if {[string match "*u_dw16*u_addr_*" $name]} { incr addr_count }
}
puts $fh "dsp48e1_cells=[llength $dsp_cells]"
puts $fh "pw112_dsp48e1_cells=$pw_count"
puts $fh "pool_dsp48e1_cells=$pool_count"
puts $fh "dw16_channel_dsp48e1_cells=$dw_count"
puts $fh "dw16_scheduler_dsp48e1_cells=$addr_count"
if {$pw_count != 112 || $pool_count != 16 || $dw_count != 16 || $addr_count != 2 || [llength $dsp_cells] != 146} { error "D4 composite timing-repair v4 DSP mapping mismatch: total=[llength $dsp_cells] pw=$pw_count pool=$pool_count dw=$dw_count addr=$addr_count" }
close $fh
exit
