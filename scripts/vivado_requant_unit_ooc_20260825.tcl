# Strict isolated post-route screen for the ten-stage requantizer.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_requant_unit_ooc_20260825]]
file mkdir $out
set part xc7z020clg400-1
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn requant_activation_unit_ooc_wrapper.v]
synth_design -top requant_activation_unit_ooc_wrapper -part $part -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -delay_type max -file [file join $out timing_summary_post_route.txt]
report_timing_summary -delay_type min -file [file join $out timing_hold_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] -max_paths 100 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] -max_paths 100 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
write_checkpoint -force [file join $out requant_unit_post_route.dcp]

set dsp_count [llength [get_cells -hier -filter {REF_NAME == DSP48E1}]]
set route_text [report_route_status -return_string]
set unrouted 1
if {[regexp {# of nets with routing errors\.*\s*:\s*([0-9]+)} $route_text -> route_errors]} {
    set unrouted $route_errors
}
set paths [get_timing_paths -delay_type max -from [all_registers] -to [all_registers] -max_paths 10000]
set worst 999.0
set bad_delay 0
foreach path $paths {
    set d [get_property DATAPATH_DELAY $path]
    if {$d < $worst} { set worst $d }
    if {$d > 8.000001} { incr bad_delay }
}
set f [open [file join $out strict_gate.txt] w]
puts $f "DSP48E1_COUNT $dsp_count"
puts $f "UNROUTED_NETS $unrouted"
puts $f "REG_REG_PATHS [llength $paths]"
puts $f "REG_REG_WORST_DATAPATH_NS $worst"
puts $f "REG_REG_PATHS_OVER_8NS $bad_delay"
if {$dsp_count != 4} { puts $f "FAIL DSP_COUNT" }
if {$unrouted != 0} { puts $f "FAIL UNROUTED" }
if {$bad_delay != 0} { puts $f "FAIL REG_REG_DELAY" }
if {$dsp_count == 4 && $unrouted == 0 && $bad_delay == 0} {
    puts $f "PASS STRUCTURAL_GATE"
} else {
    puts $f "FAIL STRUCTURAL_GATE"
}
close $f
puts "SCREEN_OUTPUT $out"
exit
