# Dynamic post-route audit.  All groups are discovered from the opened DCP;
# no endpoint names from an earlier implementation are embedded here.
set out [file normalize [file join [file dirname [info script]] .. build reports vivado_stem_addr_fma_candidate_20260825_retry3]]
open_checkpoint [file join $out candidate_post_route.dcp]
proc cells_re {re} {
    set r {}
    foreach c [get_cells -hier -filter {IS_SEQUENTIAL}] {
        if {[regexp -nocase $re [get_property NAME $c]]} { lappend r $c }
    }
    return $r
}
proc pins_dir {cells dir} {
    set r {}
    foreach c $cells {
        foreach p [get_pins -of_objects $c] {
            if {[regexp "/${dir}$" [get_property NAME $p]]} { lappend r $p }
        }
    }
    return $r
}
proc must {label objs} {
    if {[llength $objs] == 0} { error "DISCOVERY_MISSING $label" }
    return $objs
}
proc report_cone {out name from to} {
    # Materialize the discovered object collections before report_timing;
    # Vivado's lazy collection handles may otherwise be rebound by a later
    # query in the same Tcl interpreter.
    set from [list {*}$from]
    set to [list {*}$to]
    set f [open [file join $out "${name}_discovered_objects.txt"] w]
    puts $f "FROM $from"; puts $f "TO $to"; close $f
    report_timing -delay_type max -from $from -to $to -max_paths 20 -file [file join $out "${name}_discovered_max.txt"]
    report_timing -delay_type min -from $from -to $to -max_paths 20 -file [file join $out "${name}_discovered_min.txt"]
}
set groups [dict create \
    addr [must addr_cells [cells_re {rd_(input|weight)_addr_reg}]] \
    operand [must operand_cells [cells_re {operand_(input|weight)}]] \
    product [must product_cells [cells_re {product_reg_[012]_reg\[}]] \
    lane [must lane_cells [cells_re {lane_reg_[012]_reg\[}]] \
    pair [must pair_cells [cells_re {pair_reg_reg\[}]] \
    total [must total_cells [cells_re {total_reg_reg\[}]]]
set fh [open [file join $out discovered_groups.txt] w]
foreach {k v} $groups {
    puts $fh "GROUP $k"
    foreach c $v { puts $fh "$c REF=[get_property REF_NAME $c]" }
}
close $fh
set addr_q [must addr_q [pins_dir [dict get $groups addr] Q]]
set operand_d [must operand_d [pins_dir [dict get $groups operand] D]]
set operand_q [must operand_q [pins_dir [dict get $groups operand] Q]]
set product_d [must product_d [pins_dir [dict get $groups product] D]]
set product_q [must product_q [pins_dir [dict get $groups product] Q]]
set lane_d [must lane_d [pins_dir [dict get $groups lane] D]]
set lane_q [must lane_q [pins_dir [dict get $groups lane] Q]]
set pair_d [must pair_d [pins_dir [dict get $groups pair] D]]
set pair_q [must pair_q [pins_dir [dict get $groups pair] Q]]
set total_d [must total_d [pins_dir [dict get $groups total] D]]
set total_q [must total_q [pins_dir [dict get $groups total] Q]]
# Run the bypass audit first, before later Vivado timing queries can mutate
# lazy object collections in the interpreter.
report_cone $out addr_to_lane_bypass_audit $addr_q $lane_d
report_cone $out addr_to_operand_dynamic $addr_q $operand_d
report_cone $out operand_to_product_dynamic $operand_q $product_d
report_cone $out product_to_lane_dynamic $product_q $lane_d
report_cone $out lane_feedback_dynamic $lane_q $lane_d
report_cone $out lane_to_pair_dynamic $lane_q $pair_d
report_cone $out pair_to_total_dynamic $pair_q $total_d
set d [get_cells -hier -filter {REF_NAME == DSP48E1}]
set fh [open [file join $out discovered_dsp_mapping.txt] w]
foreach c $d { puts $fh "$c NAME=[get_property NAME $c]" }
close $fh
exit
