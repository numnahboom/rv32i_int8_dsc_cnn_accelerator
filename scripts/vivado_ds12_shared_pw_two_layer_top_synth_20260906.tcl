# M1 shared-PW top synthesis-only gate.  This is not routed timing evidence.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports ds12_shared_pw_two_layer_top_synth_20260906]]
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
set sf [open [file join $out run_settings.txt] w]
puts $sf "tool=Vivado 2025.2"
puts $sf "part=$part"
puts $sf "top=$top"
puts $sf "mode=synth-only out_of_context"
puts $sf "directive=Default"
puts $sf "clock_period_ns=8.000"
puts $sf "max_threads=1"
close $sf
set mf [open [file join $out source_manifest.txt] w]
foreach f $files {
    set p [file normalize [file join $root $f]]
    if {![file exists $p]} { error "missing RTL source: $p" }
    puts $mf $p
    read_verilog -sv $p
}
close $mf
synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none -directive Default
create_clock -name clk -period 8.000 [get_ports clk]
report_utilization -hierarchical -file [file join $out utilization_synth_hierarchical.rpt]
report_utilization -file [file join $out utilization_synth.rpt]
report_timing_summary -delay_type max -max_paths 40 -report_unconstrained -file [file join $out timing_summary_synth_estimate.rpt]
report_compile_order -used_in synthesis -file [file join $out compile_order_synthesis.rpt]
write_checkpoint -force [file join $out ds12_shared_pw_two_layer_top_synth.dcp]
puts "DS12_SHARED_PW_SYNTH_DONE out=$out top=$top part=$part"
exit
