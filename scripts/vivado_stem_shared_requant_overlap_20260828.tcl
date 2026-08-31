# Isolated 8 ns post-route screen for the Stem shared requant overlap.
set root [file normalize [file join [file dirname [info script]] ..]]
set out_name vivado_stem_shared_requant_overlap_20260828
if {[info exists ::env(STEM_OOC_OUT)]} { set out_name $::env(STEM_OOC_OUT) }
set out [file normalize [file join $root build reports $out_name]]
file mkdir $out
set part xc7z020clg400-1
set stem [file join $root rtl cnn conv3x3_stem_engine_new.v]
set rq [file join $root rtl cnn requant_activation_unit.v]
set mf [open [file join $out manifest.txt] w]
puts $mf "date [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %z}]"
puts $mf "stem $stem"
puts $mf "requant $rq"
puts $mf "stem_sha256 [exec powershell -NoProfile -Command \"(Get-FileHash -Algorithm SHA256 -LiteralPath '$stem').Hash\"]"
puts $mf "requant_sha256 [exec powershell -NoProfile -Command \"(Get-FileHash -Algorithm SHA256 -LiteralPath '$rq').Hash\"]"
close $mf

read_verilog -sv $rq
read_verilog -sv $stem
synth_design -top conv3x3_stem_engine_new -part $part \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
write_checkpoint -force [file join $out stem_shared_requant_overlap_synth.dcp]
create_clock -period 8.000 -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -delay_type max -file [file join $out timing_summary_post_route.txt]
report_timing_summary -delay_type min -file [file join $out timing_hold_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] -max_paths 200 \
    -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] -max_paths 200 \
    -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
write_checkpoint -force [file join $out stem_shared_requant_overlap_post_route.dcp]
puts "SCREEN_OUTPUT $out"
exit
