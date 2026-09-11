# Synth-only screen for the packed-memory group bridge.  This intentionally
# stops before placement/routing; it is the cheap gate before the routed OOC.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_group_published_shared64_runner_adapter_synth_20260903]]
file mkdir $out
set_param general.maxThreads 8
set sf [open [file join $out run_settings.txt] w]
puts $sf "tool=Vivado 2025.2"
puts $sf "part=xc7z020clg400-1"
puts $sf "top=ds_group_published_shared64_runner_adapter"
puts $sf "mode=out_of_context synth-only"
puts $sf "clock_period_ns=8.000"
close $sf
foreach f {
    rtl/cnn/systolic_pe.v
    rtl/cnn/requant_activation_unit.v
    rtl/cnn/pw_direct_8x8_dsp_rowbank.v
    rtl/cnn/unified64_shared_compute_array.v
    rtl/cnn/ds_spatial_word_window_bank.v
    rtl/cnn/ds_word_window_fill_engine.v
    rtl/cnn/ds_word_window_pingpong_shell.v
    rtl/cnn/dw_direct_3x3_dsp.v
    rtl/cnn/dw_direct_3x3_dsp_prefetched.v
    rtl/cnn/dw_direct_3x3_dsp_quadlocal.v
    rtl/cnn/ds_word_window_dw_producer_island.v
    rtl/cnn/requant_activation_stream4.v
    rtl/cnn/requant_activation_stream4_masked.v
    rtl/cnn/ds_dw_requant_stream4_write_adapter.v
    rtl/cnn/ds_dw_requant_stream4_write_adapter_local.v
    rtl/cnn/ds_pw_spatial_tile_bank_tagless.v
    rtl/cnn/ds_word_window_dw_tagless_stream4_pipeline.v
    rtl/cnn/ds_word_window_dw_tagless_stream4_4x8.v
    rtl/cnn/ds_group_published_shared64_sweep.v
    rtl/cnn/ds_group_feature_word_address_adapter.v
    rtl/cnn/ds_group_published_shared64_runner_adapter.v
} { read_verilog -sv [file join $root $f] }
synth_design -top ds_group_published_shared64_runner_adapter \
    -part xc7z020clg400-1 -flatten_hierarchy rebuilt -mode out_of_context \
    -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
report_utilization -hierarchical -file [file join $out utilization_synth.txt]
report_utilization -file [file join $out utilization_synth_flat.txt]
set ram_cells [get_cells -hierarchical -filter {PRIMITIVE_TYPE =~ RAMB*}]
set rf [open [file join $out memory_primitives.txt] w]
puts $rf "RAMB_count=[llength $ram_cells]"
foreach c $ram_cells { puts $rf [get_property NAME $c] }
close $rf
write_checkpoint -force [file join $out ds_group_published_shared64_runner_adapter_synth.dcp]
puts "GROUP_PUBLISHED_RUNNER_ADAPTER_SYNTH_DONE out=$out"
exit
