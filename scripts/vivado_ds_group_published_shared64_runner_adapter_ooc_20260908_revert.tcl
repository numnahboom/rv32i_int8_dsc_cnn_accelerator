# XC7Z020 8 ns routed OOC evidence for the current reverted request-path source.
# This is an isolated bridge OOC boundary, not a cnn_top/full-top run.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_group_published_shared64_runner_adapter_ooc_20260908_revert]]
file mkdir $out

set requested_threads 8
set_param general.maxThreads $requested_threads
set actual_threads [get_param general.maxThreads]
if {$actual_threads != $requested_threads} {
    error "general.maxThreads did not take effect: requested=$requested_threads actual=$actual_threads"
}
set settings_file [open [file join $out run_settings.txt] w]
puts $settings_file "tool=Vivado 2025.2"
puts $settings_file "part=xc7z020clg400-1"
puts $settings_file "clock_period_ns=8.000"
puts $settings_file "general.maxThreads=$actual_threads"
puts $settings_file "implementation=OOC synth/place/phys_opt/route"
puts $settings_file "route_directive=Explore"
puts $settings_file "top=ds_group_published_shared64_runner_adapter"
puts $settings_file "boundary=real six-shape group-published runner adapter; not full top"
puts $settings_file "source_state=current worktree after request-pipe revert"
close $settings_file

# Keep this inventory aligned with the current bridge simulation filelist.  The
# adapter and all arithmetic/producer RTL are read from the current worktree;
# no legacy sweep-only source or full cnn_top is substituted.
foreach f {
    rtl/cnn/systolic_pe.v
    rtl/cnn/requant_activation_unit.v
    rtl/cnn/pw_direct_8x8_dsp_rowbank.v
    rtl/cnn/unified64_shared_compute_array.v
    rtl/cnn/ds_spatial_word_window_bank.v
    rtl/cnn/ds_word_window_fill_engine.v
    rtl/cnn/ds_word_window_pingpong_shell.v
    rtl/cnn/dw_direct_3x3_dsp.v
    rtl/cnn/dw_direct_3x3_dsp_prefetched.v
    rtl/cnn/dw_direct_3x3_dsp_quadlocal.v
    rtl/cnn/ds_word_window_dw_producer_island.v
    rtl/cnn/requant_activation_stream4.v
    rtl/cnn/requant_activation_stream4_masked.v
    rtl/cnn/ds_dw_requant_stream4_write_adapter.v
    rtl/cnn/ds_dw_requant_stream4_write_adapter_local.v
    rtl/cnn/ds_pw_spatial_tile_bank_tagless.v
    rtl/cnn/ds_word_window_dw_tagless_stream4_pipeline.v
    rtl/cnn/ds_word_window_dw_tagless_stream4_4x8.v
    rtl/cnn/ds_group_published_shared64_sweep.v
    rtl/cnn/ds_group_feature_word_address_adapter.v
    rtl/cnn/ds_group_published_shared64_runner_adapter.v
} {
    read_verilog -sv [file join $root $f]
}

synth_design -top ds_group_published_shared64_runner_adapter \
    -part xc7z020clg400-1 -flatten_hierarchy rebuilt \
    -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
set_clock_uncertainty -setup 0.000 [get_clocks clk]
set_clock_uncertainty -hold 0.000 [get_clocks clk]

place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore

report_timing_summary -delay_type min_max -max_paths 100 \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_design_analysis -congestion -file [file join $out congestion_post_route.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_group_published_shared64_runner_adapter_ooc_post_route.dcp]
puts "GROUP_PUBLISHED_RUNNER_ADAPTER_OOC_DONE out=$out general.maxThreads=$actual_threads clock_period_ns=8.000"
exit
