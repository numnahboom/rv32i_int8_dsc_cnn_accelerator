set dcp [file normalize [file join [file dirname [info script]] .. build reports vivado_cnn_top cnn_top_synth.dcp]]
open_checkpoint $dcp
create_clock -add -period 8.000 -name clk8 [get_ports clk]
report_timing_summary -file [file normalize [file join [file dirname [info script]] .. build reports tiled_loader_8ns_timing_summary.txt]]
set f [open [file normalize [file join [file dirname [info script]] .. build reports tiled_loader_8ns_cells.txt]] w]
foreach c [get_cells -hier -filter {IS_SEQUENTIAL}] {
    set n [get_property NAME $c]
    if {[regexp -nocase {tiled|tile_sched|src_|load_|padding|cursor} $n]} { puts $f "$n REF=[get_property REF_NAME $c]" }
}
foreach c [get_cells -hier -filter {REF_NAME =~ DSP48*}] { puts $f "DSP $c" }
puts $f "RUNNER_PATHS"
set paths [get_timing_paths -max_paths 5000 -slack_lesser_than 100000]
foreach p $paths {
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    if {[string match *u_layer_runner* $sp] || [string match *u_layer_runner* $ep]} {
        puts $f "slack=[get_property SLACK $p] delay=[get_property DATAPATH_DELAY $p] start=$sp end=$ep"
    }
}
puts $f "RUNNER_TO_RUNNER"
set rcells [get_cells -hier -filter {NAME =~ *u_layer_runner* && IS_SEQUENTIAL}]
set rq [get_pins -of_objects $rcells -filter {REF_PIN_NAME == Q}]
set rd [get_pins -of_objects $rcells -filter {REF_PIN_NAME == D}]
foreach p [get_timing_paths -from $rq -to $rd -max_paths 2000 -slack_lesser_than 100000] {
    puts $f "slack=[get_property SLACK $p] delay=[get_property DATAPATH_DELAY $p] start=[get_property STARTPOINT_PIN $p] end=[get_property ENDPOINT_PIN $p]"
}
close $f
exit
