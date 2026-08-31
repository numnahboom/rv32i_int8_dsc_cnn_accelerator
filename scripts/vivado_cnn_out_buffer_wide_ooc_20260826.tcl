# Isolated post-route OOC check for the widened internal output buffer.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_cnn_out_buffer_wide_ooc_20260826]]
file mkdir $out
read_verilog -sv [file join $root rtl cnn cnn_layer_runner.v]
synth_design -top cnn_out_buffer -part xc7z020clg400-1 \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_utilization -file [file join $out utilization.txt]
report_utilization -hierarchical -file [file join $out utilization_hierarchical.txt]
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $out timing_summary.txt]
report_timing -delay_type max -max_paths 20 -file [file join $out timing_maxpaths.txt]
report_clock_utilization -file [file join $out clock_utilization.txt]
report_route_status -file [file join $out route_status.txt]
write_checkpoint -force [file join $out cnn_out_buffer_wide_ooc.dcp]
exit
