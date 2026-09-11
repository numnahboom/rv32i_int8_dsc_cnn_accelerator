# XC7Z020 8 ns retained DS1 OOC resource/timing check after packing the
# pointwise replay operands into one 128-bit x 128 BRAM-inferable bank.
# This is intentionally the same retained-only source set as the established
# threads=8 OOC run, with a distinct output directory for comparable evidence.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds1_retained_full_layer_orchestrator_ooc_bram_threads8_20260901]]
file mkdir $out

set requested_threads 8
set_param general.maxThreads $requested_threads
set actual_threads [get_param general.maxThreads]
if {$actual_threads != $requested_threads} {
    error "general.maxThreads did not take effect: requested=$requested_threads actual=$actual_threads"
}
set settings_file [open [file join $out run_settings.txt] w]
puts $settings_file "tool=Vivado"
puts $settings_file "part=xc7z020clg400-1"
puts $settings_file "clock_period_ns=8.000"
puts $settings_file "general.maxThreads=$actual_threads"
puts $settings_file "route_directive=Explore"
puts $settings_file "replay_storage=single_128b_x_128_ram_style_block"
close $settings_file
puts "DS1_RETAINED_BRAM_OOC_SETTINGS general.maxThreads=$actual_threads clock_period_ns=8.000 route_directive=Explore"

set part xc7z020clg400-1

foreach f {
    rtl/cnn/systolic_pe.v
    rtl/cnn/pw_systolic_array_8x8.v
    rtl/cnn/ds1_group_fill_address_adapter.v
    rtl/cnn/ds1_pw_replay_controller.v
    rtl/cnn/ds_spatial_word_window_bank.v
    rtl/cnn/ds_word_window_fill_engine.v
    rtl/cnn/ds_word_window_pingpong_shell.v
    rtl/cnn/dw_direct_3x3_dsp.v
    rtl/cnn/dw_direct_3x3_dsp_prefetched.v
    rtl/cnn/dw_direct_3x3_dsp_quadlocal.v
    rtl/cnn/ds_word_window_dw_producer_island.v
    rtl/cnn/requant_activation_unit.v
    rtl/cnn/requant_activation_stream4.v
    rtl/cnn/requant_activation_stream4_masked.v
    rtl/cnn/ds_dw_requant_stream4_write_adapter.v
    rtl/cnn/ds_dw_requant_stream4_write_adapter_local.v
    rtl/cnn/ds_pw_spatial_tile_bank_tagless.v
    rtl/cnn/ds_word_window_dw_tagless_stream4_pipeline.v
    rtl/cnn/ds_word_window_dw_tagless_stream4_4x8.v
    rtl/cnn/ds1_retained_session_wrapper.v
    rtl/cnn/ds1_retained_microgroup_bridge.v
    rtl/cnn/ds1_final_requant_write.v
    rtl/cnn/ds1_retained_full_layer_orchestrator.v
} {
    read_verilog -sv [file join $root $f]
}

synth_design -top ds1_retained_full_layer_orchestrator -part $part \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
report_utilization -file [file join $out utilization_synth.txt]
report_utilization -hierarchical -file [file join $out utilization_hierarchical_synth.txt]
report_timing_summary -delay_type min_max -max_paths 100 \
    -file [file join $out timing_summary_synth.txt]
write_checkpoint -force [file join $out ds1_retained_full_layer_orchestrator_ooc_bram_threads8_synth.dcp]

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
report_utilization -hierarchical -file [file join $out utilization_hierarchical_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_design_analysis -congestion -file [file join $out congestion_post_route.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds1_retained_full_layer_orchestrator_ooc_bram_threads8_post_route.dcp]
puts "DS1_RETAINED_BRAM_OOC_DONE out=$out general.maxThreads=$actual_threads"
exit
