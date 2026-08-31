set out [file normalize [file join [file dirname [info script]] .. build reports vivado_stem_addr_fma_candidate_20260825_retry3]]
open_checkpoint [file join $out candidate_post_route.dcp]
set ac {}; set lc {}
foreach c [get_cells -hier -filter {IS_SEQUENTIAL}] {
    set n [get_property NAME $c]
    if {[regexp {rd_(input|weight)_addr_reg} $n]} {
        foreach p [get_pins -of_objects $c] { if {[regexp {/Q$} [get_property NAME $p]]} {lappend ac $p} }
    }
    if {[regexp {lane_reg_[012]_reg\[} $n]} {
        foreach p [get_pins -of_objects $c] { if {[regexp {/D$} [get_property NAME $p]]} {lappend lc $p} }
    }
}
if {[llength $ac] == 0 || [llength $lc] == 0} {error "DISCOVERY_MISSING addr_or_lane"}
set f [open [file join $out addr_to_lane_bypass_fresh_objects.txt] w]
puts $f "FROM $ac"; puts $f "TO $lc"; close $f
set a0 [get_property NAME [lindex $ac 0]]
set l0 [get_property NAME [lindex $lc 0]]
# Use scalar discovered pin names for the timing query: Vivado mutates large
# object collections while evaluating report_timing, whereas scalar pins are
# stable and make the command line auditable.
report_timing -delay_type max -from $a0 -to $l0 -max_paths 1 -file [file join $out addr_to_lane_bypass_fresh_max.txt]
report_timing -delay_type min -from $a0 -to $l0 -max_paths 1 -file [file join $out addr_to_lane_bypass_fresh_min.txt]
exit
