# Read-only structural dump for a v6 synthesis checkpoint.
# argv: dcp verilog-out
if {[llength $argv] < 2} {
    error "usage: vivado -mode batch -source dump_v6_synth_netlist_20260910.tcl -tclargs <dcp> <verilog-out>"
}
set dcp [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
open_checkpoint $dcp
write_verilog -force -mode timesim $out
close_design
exit
