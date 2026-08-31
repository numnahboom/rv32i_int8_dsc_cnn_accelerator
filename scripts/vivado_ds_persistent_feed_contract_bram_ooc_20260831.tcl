set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build reports vivado_ds_persistent_feed_contract_bram_ooc_20260831]
file mkdir $out_dir
create_project -in_memory ds_persistent_feed_contract_bram_ooc
set_part xc7z020clg400-1
read_verilog -sv [file join $root rtl cnn ds_persistent_feed_contract_bram.v]
synth_design -top ds_persistent_feed_contract -part xc7z020clg400-1 -mode out_of_context
create_clock -name clk -period 8.000 [get_ports clk]
set_clock_uncertainty 0.100 [get_clocks clk]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -delay_type max -max_paths 20 -file [file join $out_dir timing_summary.rpt]
report_timing -max_paths 20 -sort_by group -file [file join $out_dir timing_max.rpt]
report_timing_summary -delay_type min -max_paths 20 -file [file join $out_dir timing_min.rpt]
report_timing -delay_type min -max_paths 20 -sort_by group -file [file join $out_dir timing_min_paths.rpt]
report_utilization -file [file join $out_dir utilization.rpt]
report_power -file [file join $out_dir power.rpt]
report_high_fanout_nets -max_nets 50 -file [file join $out_dir high_fanout.rpt]
write_checkpoint -force [file join $out_dir ds_persistent_feed_contract_bram_ooc.dcp]
close_project
