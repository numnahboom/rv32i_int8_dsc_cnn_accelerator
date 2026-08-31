set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_group_published_shared64_sweep_ooc_20260831_rerun6]]
file mkdir $out
set_param general.maxThreads 1
read_verilog -sv [file join $root rtl cnn pw_direct_8x8_dsp_rowbank.v]
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn unified64_shared_compute_array.v]
read_verilog -sv [file join $root rtl cnn ds_group_published_shared64_sweep.v]
synth_design -top ds_group_published_shared64_sweep -part xc7z020clg400-1 -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
report_timing_summary -delay_type min_max -max_paths 100 -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_design_analysis -congestion -file [file join $out congestion_post_route.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_group_published_shared64_sweep_ooc_post_route.dcp]
exit
