# DS12 pure DS1->DS2 composition: XC7Z020 synthesis-only resource screen.
# This stops after synth_design; it is not placement, routing, timing closure,
# post-route utilization, hardware validation, or full-network evidence.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports ds12_stream_pure_two_layer_top_synth_20260905]]
file mkdir $out

set part xc7z020clg400-1
set top ds12_stream_pure_two_layer_top
set clock_period_ns 8.000
set_param general.maxThreads 1

set files {
    rtl/cnn/ds12_stream_vector_lane_bank.v
    rtl/cnn/ds12_stream_dual_vector_activation_store.v
    rtl/cnn/ds12_stream_config_banks.v
    rtl/cnn/ds12_stream_ds1_dw_endpoint.v
    rtl/cnn/ds12_stream_ds1_pw_consumer.v
    rtl/cnn/ds12_stream_ds1_datapath.v
    rtl/cnn/ds12_stream_ds2_window_vector_reader.v
    rtl/cnn/ds12_stream_ds2_window_reader.v
    rtl/cnn/ds12_stream_ds2_dw_compute.v
    rtl/cnn/ds12_stream_ds2_pw_consumer.v
    rtl/cnn/ds12_stream_ds2_datapath.v
    rtl/cnn/ds12_stream_pure_two_layer_top.v
}

set sf [open [file join $out run_settings.txt] w]
puts $sf "tool=Vivado 2025.2"
puts $sf "part=$part"
puts $sf "top=$top"
puts $sf "mode=synth-only"
puts $sf "synth_mode=out_of_context"
puts $sf "directive=Default"
puts $sf "clock_period_ns=$clock_period_ns"
puts $sf "max_threads=1"
puts $sf "source_manifest=[file join $out source_manifest.txt]"
close $sf

set mf [open [file join $out source_manifest.txt] w]
foreach f $files {
    set p [file normalize [file join $root $f]]
    if {![file exists $p]} { error "missing RTL source: $p" }
    puts $mf $p
    read_verilog -sv $p
}
close $mf

synth_design -top $top -part $part -mode out_of_context \
    -flatten_hierarchy none -directive Default
create_clock -name clk -period $clock_period_ns [get_ports clk]

# These are the authoritative post-synthesis utilization reports for this run.
report_utilization -hierarchical -file [file join $out utilization_synth_hierarchical.rpt]
report_utilization -file [file join $out utilization_synth.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $out timing_summary_synth_estimate.rpt]
report_compile_order -used_in synthesis \
    -file [file join $out compile_order_synthesis.rpt]

write_checkpoint -force [file join $out ds12_stream_pure_two_layer_top_synth.dcp]
puts "DS12_PURE_TWO_LAYER_SYNTH_DONE out=$out top=$top part=$part"
exit
