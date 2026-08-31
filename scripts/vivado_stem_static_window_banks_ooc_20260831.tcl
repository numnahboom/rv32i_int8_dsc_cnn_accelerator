# Static row-bank / byte-lane 64-MAC Stem OOC implementation screen.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_stem_static_window_banks_ooc_20260831]]
file mkdir $out
set_param general.maxThreads 2
set part xc7z020clg400-1
read_verilog -sv [file join $root rtl common requant_activation_core.v]
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn stem_weight_store_packed64.v]
read_verilog -sv [file join $root rtl cnn stem_unified64_streaming.v]
synth_design -top stem_static_window_banks -part $part -flatten_hierarchy none \
    -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
report_utilization -file [file join $out utilization_synth.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_synth.txt]
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
write_checkpoint -force [file join $out stem_static_window_banks_post_route.dcp]
exit
