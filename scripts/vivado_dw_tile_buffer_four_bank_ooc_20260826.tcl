set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_dw_tile_buffer_four_bank_ooc_20260826]]
file mkdir $out
read_verilog -sv [file join $root rtl cnn dw_tile_buffer_bram.v]
synth_design -top dw_tile_buffer_bram -part xc7z020clg400-1 -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -period 8.000 -name clk [get_ports clk]
place_design
route_design
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $out timing_summary.txt]
report_utilization -file [file join $out utilization.txt]
report_route_status -file [file join $out route_status.txt]
report_power -file [file join $out power.txt]
report_drc -file [file join $out drc.txt]
write_checkpoint -force [file join $out dw_tile_buffer_four_bank_ooc.dcp]
exit
