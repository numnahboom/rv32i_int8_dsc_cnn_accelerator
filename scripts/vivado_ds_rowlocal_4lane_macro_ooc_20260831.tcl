set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_rowlocal_4lane_macro_ooc_20260831]]
file mkdir $out
set part xc7z020clg400-1
set_param general.maxThreads 2

read_verilog -sv \
    [file join $root rtl cnn requant_activation_unit.v] \
    [file join $root rtl cnn requant_activation_stream4.v] \
    [file join $root rtl cnn ds_rowlocal_4lane_macro.v]
synth_design -top ds_rowlocal_4lane_macro -part $part \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore

report_timing_summary -delay_type min_max -max_paths 100 \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out timing_max_post_route.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out timing_min_post_route.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_high_fanout_nets -timing -load_types -max_nets 100 \
    -file [file join $out high_fanout_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_rowlocal_4lane_macro_ooc_post_route.dcp]
puts "DS_ROWLOCAL_OOC_DONE $out"
exit
