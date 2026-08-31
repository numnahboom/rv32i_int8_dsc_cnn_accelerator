# 8 ns XC7Z020 post-route screen for the isolated feeder composition.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_native_word_response_pipe_vector16_shell_ooc_20260829]]
file mkdir $out
set_param general.maxThreads 2
read_verilog -sv [file join $root rtl cnn native_word_response_pipe.v]
read_verilog -sv [file join $root rtl cnn feature_tile_pingpong_ctrl.v]
read_verilog -sv [file join $root rtl cnn feature_tile_vector16_bank.v]
read_verilog -sv [file join $root rtl cnn feature_tile_vector16_pingpong_shell.v]
read_verilog -sv [file join $root rtl cnn native_word_response_pipe_vector16_shell.v]
synth_design -top native_word_response_pipe_vector16_shell -part xc7z020clg400-1 \
  -generic MAX_CHANNELS=48 -generic MAX_IN_H=10 -generic MAX_IN_W=10 \
  -generic FIFO_DEPTH=64 -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
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
write_checkpoint -force [file join $out native_word_response_pipe_vector16_shell_ooc_post_route.dcp]
exit
