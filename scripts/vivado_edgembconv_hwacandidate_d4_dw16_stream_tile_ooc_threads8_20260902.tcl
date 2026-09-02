set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build reports vivado_edgembconv_hwacandidate_d4_dw16_stream_tile_ooc_threads8_20260902]
file mkdir $out
set_param general.maxThreads 8
set_part xc7z020clg400-1
read_verilog -sv [file join $root rtl cnn edgembconv_hwacandidate_d4_dw16_stream_tile.v]
synth_design -top edgembconv_hwacandidate_d4_dw16_stream_tile -part xc7z020clg400-1 \
    -flatten_hierarchy rebuilt -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
report_utilization -file [file join $out utilization_post_synth.txt]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $out timing_summary_post_route.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_route_status -file [file join $out route_status.txt]
set f [open [file join $out run_settings.txt] a]
puts $f "general.maxThreads=[get_param general.maxThreads]"
puts $f "part=xc7z020clg400-1"
puts $f "clock_period_ns=8.000"
close $f
exit
