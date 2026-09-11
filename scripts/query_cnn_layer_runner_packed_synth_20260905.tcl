# Read-only post-synthesis DCP query for the packed loader evidence.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_cnn_layer_runner_packed_synth_20260905]]
open_checkpoint [file join $out cnn_layer_runner_packed_synth.dcp]
set qf [open [file join $out packed_loader_dcp_query.txt] w]
puts $qf "design=[get_property NAME [current_design]]"
foreach pat {*gen_packed_shadow* *u_packed_shadow_memory* *packed_shadow* *pw_weight_buffer* *u_pw_weight_buffer* *u_weight_memory*} {
    set cs [get_cells -hierarchical -quiet $pat]
    puts $qf "cell_query=$pat count=[llength $cs]"
    foreach c $cs {
        puts $qf "  cell=[get_property NAME $c] ref=[get_property REF_NAME $c] orig=[get_property ORIG_REF_NAME $c]"
    }
}
foreach pat {*cfg_weight_word* *packed_weight*} {
    set ns [get_nets -hierarchical -quiet $pat]
    puts $qf "net_query=$pat count=[llength $ns]"
    foreach n [lrange $ns 0 20] { puts $qf "  net=[get_property NAME $n]" }
}
set brams [get_cells -hierarchical -quiet -filter {REF_NAME =~ RAMB*}]
puts $qf "ramb_cells=[llength $brams]"
set buffer_cells [get_cells -hierarchical -quiet -filter {REF_NAME =~ RAMB* && NAME =~ *u_pw_weight_buffer*}]
puts $qf "buffer_ramb_cells=[llength $buffer_cells]"
foreach c $buffer_cells {
    puts $qf "buffer_ramb=[get_property NAME $c] ref=[get_property REF_NAME $c]"
}
foreach c $brams {
    set n [get_property NAME $c]
    if {[string match *u_pw_weight_buffer* $n] || [string match *u_weight_memory* $n]} {
        puts $qf "loader_ramb=[get_property NAME $c] ref=[get_property REF_NAME $c]"
    }
}
close $qf
exit
