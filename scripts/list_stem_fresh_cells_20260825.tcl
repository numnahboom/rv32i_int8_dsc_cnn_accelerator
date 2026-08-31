set out [file normalize [file join [file dirname [info script]] .. build reports vivado_stem_addr_fma_candidate_fresh_20260825]]
open_checkpoint [file join $out candidate_post_route.dcp]
set f [open [file join $out all_sequential_cells.txt] w]
foreach c [get_cells -hier -filter {IS_SEQUENTIAL}] {
    set n [get_property NAME $c]
    puts $f "$c REF=[get_property REF_NAME $c]"
}
close $f
set f [open [file join $out all_dsp_cells_pins.txt] w]
foreach c [get_cells -hier -filter {REF_NAME == DSP48E1}] {
    puts $f "CELL $c"
    foreach p [get_pins -of_objects $c] { puts $f "  $p REF_PIN_NAME=[get_property REF_PIN_NAME $p]" }
}
close $f
exit
