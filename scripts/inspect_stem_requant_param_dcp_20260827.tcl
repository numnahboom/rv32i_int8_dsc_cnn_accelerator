set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_stem_requant_param_capture_20260827]]
open_checkpoint [file join $out stem_requant_param_capture_post_route.dcp]
set f [open [file join $out discovered_sequential_cells.txt] w]
foreach c [get_cells -hier] {
    set n [get_property NAME $c]
    if {[regexp -nocase {channel|rq|multiplier|product|bias|shift} $n]} {
        puts $f "$c REF=[get_property REF_NAME $c]"
        foreach p [get_pins -of_objects $c] {
            set pn [get_property NAME $p]
            if {[regexp {/(D|Q|C)$} $pn]} { puts $f "  $p" }
        }
    }
}
close $f
proc pins_matching {label re suffix} {
    set result {}
    set pin_re [format {/%s(\[[0-9]+\])?$} $suffix]
    foreach c [get_cells -hier] {
        if {[regexp -nocase $re [get_property NAME $c]]} {
            foreach p [get_pins -of_objects $c] {
                if {[regexp $pin_re [get_property NAME $p]]} { lappend result $p }
            }
        }
    }
    if {[llength $result] == 0} { error "DISCOVERY_MISSING $label" }
    return $result
}
set channel_q [pins_matching channel_q {^channel_idx_reg} Q]
set product_c [pins_matching product_c {^rq_product_reg_reg__0} C]
set gf [open [file join $out discovered_groups.txt] w]
puts $gf "GROUP channel_q"
foreach p $channel_q { puts $gf $p }
puts $gf "GROUP product_c"
foreach p $product_c { puts $gf $p }
close $gf
set af [open [file join $out channel_to_product_objects.txt] w]
puts $af "FROM $channel_q"
puts $af "TO $product_c"
close $af
if {[catch {report_timing -delay_type max -from $channel_q -to $product_c -max_paths 20 \
    -file [file join $out channel_to_product_max.txt]} err]} {
    set af [open [file join $out channel_to_product_max.txt] w]
    puts $af "NO_TIMING_PATH $err"
    close $af
}
exit
