# Dynamic audit of the fresh post-route stem DCP.  This script intentionally
# fails the total-stage gate when Vivado optimizes total_reg away.
set out [file normalize [file join [file dirname [info script]] .. build reports vivado_stem_addr_fma_candidate_fresh_20260825]]
open_checkpoint [file join $out candidate_post_route.dcp]
proc seq_cells {re} {
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
proc cone {out name from to} {
    set from [list {*}$from]; set to [list {*}$to]
    set f [open [file join $out "${name}_objects.txt"] w]
    puts $f "FROM $from"; puts $f "TO $to"; close $f
    report_timing -delay_type max -from $from -to $to -max_paths 20 -file [file join $out "${name}_max.txt"]
    report_timing -delay_type min -from $from -to $to -max_paths 20 -file [file join $out "${name}_min.txt"]
}
set cursor [must cursor [seq_cells {(input|weight)_addr_cursor_reg}]]
set addr [must addr [seq_cells {addr_(input|weight)_[012]_reg}]]
set operand [must operand [seq_cells {operand_(act|weight)_[012]_reg}]]
set product [must product [seq_cells {product_reg_[012]_reg}]]
set lane [must lane [seq_cells {lane_acc_[012]_reg}]]
set pair [must pair [seq_cells {pair_reg_reg}]]
set cursor_q [must cursor_q [pins_dir $cursor Q]]
set addr_d [must addr_d [pins_dir $addr D]]
set addr_q [must addr_q [pins_dir $addr Q]]
set operand_d [must operand_d [pins_dir $operand D]]
set operand_q [must operand_q [pins_dir $operand Q]]
set product_d [must product_d [pins_dir $product D]]
set product_q [must product_q [pins_dir $product Q]]
set lane_d [must lane_d [pins_dir $lane D]]
set lane_q [must lane_q [pins_dir $lane Q]]
set pair_d [must pair_d [pins_dir $pair D]]
set pair_q [must pair_q [pins_dir $pair Q]]
cone $out cursor_to_rd_addr $cursor_q $addr_d
cone $out rd_addr_to_operand $addr_q $operand_d
cone $out operand_to_product $operand_q $product_d
cone $out product_to_lane $product_q $lane_d
cone $out lane_feedback $lane_q $lane_d
cone $out lane_to_pair $lane_q $pair_d

# A scalar address-Q to lane-D audit is the explicit no-bypass check.
set f [open [file join $out addr_to_lane_bypass_objects.txt] w]
puts $f "FROM [lindex $addr_q 0]"; puts $f "TO [lindex $lane_d 0]"; close $f
report_timing -delay_type max -from [lindex $addr_q 0] -to [lindex $lane_d 0] -max_paths 1 -file [file join $out addr_to_lane_bypass_max.txt]
report_timing -delay_type min -from [lindex $addr_q 0] -to [lindex $lane_d 0] -max_paths 1 -file [file join $out addr_to_lane_bypass_min.txt]

set failures {}
set total [seq_cells {total_reg_reg}]
if {[llength $total] == 0} {
    lappend failures total_reg_removed_by_synthesis
    set f [open [file join $out total_stage_gate.txt] w]
    puts $f "FAIL total_reg_removed_by_synthesis"
    puts $f "The fresh post-route DCP has no total_reg D pin/Q pin; total+bias DSP-input gate is not claimable."
    close $f
} else {
    set total_d [must total_d [pins_dir $total D]]
    set total_q [must total_q [pins_dir $total Q]]
    cone $out pair_to_total $pair_q $total_d
    set dsp_inputs {}
    foreach c [get_cells -hier -filter {REF_NAME == DSP48E1}] {
        foreach p [get_pins -of_objects $c] {
            if {[regexp {^(A|B|C|D|AD|INMODE|OPMODE|ALUMODE|CARRYIN|MULTSIGNIN)} [get_property REF_PIN_NAME $p]]} { lappend dsp_inputs $p }
        }
    }
    set dsp_inputs [must dsp_inputs $dsp_inputs]
    report_timing -delay_type max -from $total_q -to $dsp_inputs -max_paths 50 -file [file join $out total_bias_to_dsp_input_max.txt]
    report_timing -delay_type min -from $total_q -to $dsp_inputs -max_paths 50 -file [file join $out total_bias_to_dsp_input_min.txt]
}
set f [open [file join $out audit_gate_result.txt] w]
if {[llength $failures] != 0} { puts $f "FAIL $failures" } else { puts $f "PASS all_discovered_targets" }
close $f
exit
