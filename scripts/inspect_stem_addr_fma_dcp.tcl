set out [file normalize [file join [file dirname [info script]] .. build reports vivado_stem_addr_fma_candidate_20260825_retry]]
open_checkpoint [file join $out candidate_post_route.dcp]
set f [open [file join $out discovered_sequential_cells.txt] w]
foreach c [get_cells -hier -filter {IS_SEQUENTIAL}] {
    set n [get_property NAME $c]
    if {[regexp -nocase {rd_|operand|product|lane|pair|total|rq_sum|bias_mem} $n]} {
        puts $f "$c REF=[get_property REF_NAME $c]"
        foreach p [get_pins -of_objects $c] {
            set pn [get_property NAME $p]
            if {[regexp {/(D|Q)$} $pn]} { puts $f "  $p" }
        }
    }
}
close $f
exit
