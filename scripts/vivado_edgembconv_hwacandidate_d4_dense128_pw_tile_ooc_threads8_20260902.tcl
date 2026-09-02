# Independent XC7Z020 OOC route proof for the D4 8x16 PW tile.
# This candidate primitive owns 128 MAC cells and does not instantiate the
# legacy 8x8 PW engine or alter any C0/production RTL path.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_edgembconv_hwacandidate_d4_dense128_pw_tile_ooc_threads8_20260902]]
file mkdir $out
set part xc7z020clg400-1
set_param general.maxThreads 8

read_verilog -sv [file join $root rtl cnn edgembconv_hwacandidate_d4_dense128_pw_tile.v]
synth_design -top edgembconv_hwacandidate_d4_dense128_pw_tile -part $part \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
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
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out edgembconv_hwacandidate_d4_dense128_pw_tile_ooc_post_route.dcp]
set fh [open [file join $out run_settings.txt] w]
puts $fh "variant=edgembconv_hwacandidate_d4_dense128_pw_tile"
puts $fh "part=$part"
puts $fh "clock_ns=8.000"
puts $fh "general.maxThreads=[get_param general.maxThreads]"
close $fh
exit
