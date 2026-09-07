# M1.1-A independent DW16 -> PW64 unit/OOC guardband.
# This source set is deliberately disjoint from the M0/M1 production tops.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports m11a_runtime_dw_pw_core_ooc_8ns]]
file mkdir $out
set part xc7z020clg400-1
set top m11a_runtime_dw_pw_core
set_param general.maxThreads 8
set files {
    rtl/cnn/m11a_dsp48e1_wrappers.v
    rtl/cnn/m11a_runtime_cfg_store.v
    rtl/cnn/m11a_dw16_shared_line.v
    rtl/cnn/m11a_context_packer.v
    rtl/cnn/m11a_pw64_shared_core.v
    rtl/cnn/m11a_runtime_dw_pw_core.v
}
set mf [open [file join $out source_manifest.txt] w]
foreach f $files {
    set p [file normalize [file join $root $f]]
    puts $mf $p
    read_verilog -sv $p
}
close $mf
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
report_utilization -hierarchical -file [file join $out utilization_post_route_hierarchical.rpt]
report_utilization -file [file join $out utilization_post_route.rpt]
report_timing_summary -delay_type max -max_paths 100 -report_unconstrained -file [file join $out timing_summary_post_route.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $out timing_max.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $out timing_min.rpt]
report_route_status -file [file join $out route_status_post_route.rpt]
report_high_fanout_nets -timing -load_types -max_nets 100 -file [file join $out high_fanout.rpt]
report_drc -file [file join $out drc_post_route.rpt]
write_checkpoint -force [file join $out m11a_runtime_dw_pw_core_ooc_8ns_post_route.dcp]
puts "M11A_RUNTIME_DW_PW_OOC_DONE out=$out top=$top part=$part"
exit
