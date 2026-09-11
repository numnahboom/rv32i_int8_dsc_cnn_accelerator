# Read-only probe for the v6 synthesis checkpoint.  argv: dcp output-report
if {[llength $argv] < 2} { error "usage: vivado -mode batch -source query_v6_synth_hierarchy_20260910.tcl -tclargs <dcp> <report>" }
set dcp [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
file mkdir [file dirname $out]
open_checkpoint $dcp
set fh [open $out w]
puts $fh "dcp=$dcp"
puts $fh "design=[get_property NAME [current_design]]"
set all [get_cells -hierarchical -quiet]
puts $fh "all_cells=[llength $all]"
foreach pattern {*u_dw_raw_fifo* *u_pool* *u_ded_pw_operand_stage* *u_pw112* *u_v6_banked_storage*} {
    set cells [get_cells -hierarchical -quiet -filter "NAME =~ $pattern"]
    puts $fh "pattern=$pattern count=[llength $cells]"
    array unset byref
    foreach c $cells {
        set ref [get_property REF_NAME $c]
        if {[info exists byref($ref)]} { incr byref($ref) } else { set byref($ref) 1 }
    }
    foreach ref [lsort [array names byref]] { puts $fh "  ref=$ref count=$byref($ref)" }
}
set lut [get_cells -hierarchical -quiet -filter {REF_NAME =~ LUT*}]
foreach pattern {*u_dw_raw_fifo* *u_pool* *u_ded_pw_operand_stage* *u_pw112*} {
    set cells [get_cells -hierarchical -quiet -filter "REF_NAME =~ LUT* && NAME =~ $pattern"]
    puts $fh "lut_pattern=$pattern count=[llength $cells]"
}
puts $fh "lut_total=[llength $lut]"
puts $fh "--- synthesis attributes ---"
foreach prop {DONT_TOUCH KEEP KEEP_HIERARCHY MARK_DEBUG} {
    set n 0
    set examples {}
    foreach c $all {
        set v [get_property -quiet $prop $c]
        if {$v eq "1" || $v eq "TRUE" || $v eq "true"} {
            incr n
            if {[llength $examples] < 40} { lappend examples "$c REF=[get_property REF_NAME $c]" }
        }
    }
    puts $fh "$prop=$n"
    foreach e $examples { puts $fh "  $e" }
}
puts $fh "--- named raw_fifo cells ---"
set raw [get_cells -hierarchical -quiet -filter {NAME =~ *u_dw_raw_fifo*}]
foreach c [lrange [lsort $raw] 0 300] {
    puts $fh "[get_property REF_NAME $c] [get_property ORIG_REF_NAME $c] $c"
}
close $fh
close_design
exit
