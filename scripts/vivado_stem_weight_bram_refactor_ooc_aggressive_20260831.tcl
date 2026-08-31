# Variant implementation screen: same XPM weight-store netlist, with the
# legal aggressive post-placement optimizer used only to test physical spread.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_stem_weight_bram_refactor_ooc_aggressive_20260831]]
file mkdir $out
set_param general.maxThreads 1
set part xc7z020clg400-1
read_verilog -sv [file join $root rtl common requant_activation_core.v]
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn stem_weight_store_packed64.v]
read_verilog -sv [file join $root rtl cnn stem_unified64_streaming.v]
synth_design -top stem_static_window_banks -part $part -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
report_timing_summary -delay_type min_max -max_paths 100 -file [file join $out timing_summary_post_route.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_post_route.txt]
report_power -file [file join $out power_post_route.txt]
write_checkpoint -force [file join $out stem_weight_bram_refactor_aggressive_post_route.dcp]
exit
