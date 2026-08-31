# Exactly one 8 ns XC7Z020 post-route feasibility screen.  This is isolated
# from cnn_top and all production runner state.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_wordstream_feasibility_ooc_20260829]]
file mkdir $out
set_param general.maxThreads 2
set part xc7z020clg400-1
read_verilog -sv \
    [file join $root rtl cnn feature_tile_word_feeder.v] \
    [file join $root rtl cnn mac16_stream_core.v] \
    [file join $root rtl cnn mac16_stream_adapters.v] \
    [file join $root rtl cnn pw_direct_8x8_dsp.v] \
    [file join $root rtl cnn requant_activation_unit.v] \
    [file join $root rtl cnn wordstream_feasibility_harness.v] \
    [file join $root rtl cnn wordstream_feasibility_ooc_wrapper.v]
synth_design -top wordstream_feasibility_ooc_wrapper -part $part -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
place_design
phys_opt_design
route_design
report_timing_summary -delay_type min_max -max_paths 100 -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out wordstream_feasibility_post_route.dcp]
exit
