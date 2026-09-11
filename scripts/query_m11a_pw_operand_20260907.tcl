# Read-only targeted timing query for the registered PW operand boundary.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports m11a_runtime_dw_pw_core_ooc_8ns]]
set dcp [file join $out m11a_runtime_dw_pw_core_ooc_8ns_post_route.dcp]
open_checkpoint $dcp
report_timing_summary -delay_type min -report_unconstrained -file [file join $out timing_summary_min_post_route.rpt]
set bram_clk [get_pins -quiet -hier -filter {NAME =~ "*cfg_store/pw_row_mem_reg/CLKARDCLK"}]
set weight_d [get_pins -quiet -hier -filter {NAME =~ "*pw64/operand_weight_reg*/D"}]
set act_d [get_pins -quiet -hier -filter {NAME =~ "*pw64/operand_activation_reg*/D"}]
set fh [open [file join $out pw_bram_to_operand_timing.rpt] w]
puts $fh "bram_clk=[join [get_property NAME $bram_clk] {; }]"
puts $fh "weight_d=[join [get_property NAME $weight_d] {; }]"
puts $fh "act_d=[join [get_property NAME $act_d] {; }]"
if {[llength $bram_clk] && [llength $weight_d]} {
    report_timing -from $bram_clk -to $weight_d -delay_type max -max_paths 10 -file [file join $out pw_bram_to_operand_weight_timing.rpt]
    puts $fh "weight_paths=[llength [get_timing_paths -from $bram_clk -to $weight_d -delay_type max -max_paths 10]]"
} else {
    puts $fh "weight_paths=0"
}
if {[llength $bram_clk] && [llength $act_d]} {
    report_timing -from $bram_clk -to $act_d -delay_type max -max_paths 10 -file [file join $out pw_bram_to_operand_activation_timing.rpt]
    puts $fh "activation_paths=[llength [get_timing_paths -from $bram_clk -to $act_d -delay_type max -max_paths 10]]"
} else {
    puts $fh "activation_paths=0"
}
close $fh
close_design
exit
