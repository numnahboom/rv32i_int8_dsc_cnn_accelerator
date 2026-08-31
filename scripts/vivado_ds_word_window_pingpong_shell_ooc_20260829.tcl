set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_word_window_pingpong_shell_ooc_20260829]]
file mkdir $out
set_param general.maxThreads 2
read_verilog -sv \
    [file join $root rtl cnn ds_spatial_word_window_bank.v] \
    [file join $root rtl cnn ds_word_window_fill_engine.v] \
    [file join $root rtl cnn ds_word_window_pingpong_shell.v] \
    [file join $root rtl cnn ds_word_window_pingpong_shell_ooc_wrapper.v]
synth_design -top ds_word_window_pingpong_shell_ooc_wrapper \
    -part xc7z020clg400-1 -flatten_hierarchy none \
    -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
opt_design
place_design
phys_opt_design -directive AggressiveExplore
route_design
report_timing_summary -delay_type min_max -max_paths 100 \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_word_window_pingpong_shell_ooc_post_route.dcp]
exit
