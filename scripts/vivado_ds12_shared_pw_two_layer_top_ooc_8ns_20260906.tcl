# M1 shared-PW routed OOC evidence.  Run only after synth-only succeeds.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports ds12_shared_pw_two_layer_top_ooc_8ns_20260906]]
file mkdir $out
set part xc7z020clg400-1
set top ds12_shared_pw_two_layer_top
set_param general.maxThreads 1
set files {
    rtl/cnn/ds12_stream_vector_lane_bank.v
    rtl/cnn/ds12_stream_dual_vector_activation_store.v
    rtl/cnn/ds12_shared_pw_ds1_dw_bram_endpoint.v
    rtl/cnn/ds12_stream_ds2_window_vector_reader.v
    rtl/cnn/ds12_stream_ds2_dw_compute.v
    rtl/cnn/ds12_shared_pw_service.v
    rtl/cnn/ds12_shared_pw_config_port.v
    rtl/cnn/ds12_shared_pw_scheduler.v
    rtl/cnn/ds12_shared_pw_ds1_adapter.v
    rtl/cnn/ds12_shared_pw_ds2_adapter.v
    rtl/cnn/ds12_shared_pw_two_layer_top.v
}
set mf [open [file join $out source_manifest.txt] w]
foreach f $files {
    set p [file normalize [file join $root $f]]
    puts $mf $p
    read_verilog -sv $p
}
close $mf
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none -directive Default
create_clock -name clk -period 8.000 [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_utilization -hierarchical -file [file join $out utilization_post_route_hierarchical.rpt]
report_utilization -file [file join $out utilization_post_route.rpt]
report_timing_summary -delay_type max -max_paths 80 -report_unconstrained -file [file join $out timing_summary_post_route.rpt]
report_route_status -file [file join $out route_status_post_route.rpt]
write_checkpoint -force [file join $out ds12_shared_pw_two_layer_top_ooc_8ns_post_route.dcp]
puts "DS12_SHARED_PW_OOC_DONE out=$out top=$top part=$part"
exit
