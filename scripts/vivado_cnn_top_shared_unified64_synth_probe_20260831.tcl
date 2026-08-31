# Full cnn_top synthesis-only probe for the shared unified64 Stem/DS island.
# This is a resource/elaboration gate only; it intentionally does not claim
# post-route timing closure.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_cnn_top_shared_unified64_synth_probe_20260831]]
file mkdir $out
set_param general.maxThreads 1
set part xc7z020clg400-1
set files [list \
    rtl/common/round_shift.v \
    rtl/common/saturate_int8.v \
    rtl/common/requant_activation_core.v \
    rtl/cnn/requant_activation_unit.v \
    rtl/cnn/requant_activation_vector4.v \
    rtl/cnn/requant_activation_stream4.v \
    rtl/cnn/requant_activation_pipeline.v \
    rtl/cnn/requant_product_pipeline.v \
    rtl/cnn/systolic_pe.v \
    rtl/cnn/pw_systolic_array_8x8.v \
    rtl/cnn/pw_direct_8x8_dsp.v \
    rtl/cnn/pw_direct_8x8_dsp_rowbank.v \
    rtl/cnn/unified64_shared_compute_array.v \
    rtl/cnn/unified64_tile_engine_experiment.v \
    rtl/cnn/dw_line_buffer.v \
    rtl/cnn/dw_mac_lanes.v \
    rtl/cnn/dw_tile_buffer_bram.v \
    rtl/cnn/ds_input_tile_buffer_bram.v \
    rtl/cnn/pw_weight_buffer_bram.v \
    rtl/cnn/dw_tile_fusion_engine_new.v \
    rtl/cnn/dw_tile_fusion_engine_vector4.v \
    rtl/cnn/ds_block_tile_engine_new.v \
    rtl/cnn/ds_persistent_pw_row_feed.v \
    rtl/cnn/conv3x3_stem_engine_new.v \
    rtl/cnn/stem_weight_store_packed64.v \
    rtl/cnn/stem_unified64_streaming.v \
    rtl/cnn/gap_unit_new.v \
    rtl/cnn/fc_unit_new.v \
    rtl/cnn/tile_scheduler.v \
    rtl/cnn/feature_sram_bank.v \
    rtl/cnn/feature_sram_pingpong.v \
    rtl/cnn/status_counter.v \
    rtl/cnn/descriptor_fetch.v \
    rtl/cnn/cnn_layer_runner.v \
    rtl/cnn/cnn_top_ctrl.v \
    rtl/cnn/cnn_top.v \
]
foreach f $files { read_verilog -sv [file join $root $f] }
read_xdc [file join $root constraints cnn_top_unified64_ooc_8ns.xdc]
puts "SHARED_FULLTOP_SYNTH_PROBE_BEFORE"
synth_design -top cnn_top -part $part -flatten_hierarchy none -mode out_of_context \
    -directive RuntimeOptimized -generic {USE_SHARED_UNIFIED64=1}
puts "SHARED_FULLTOP_SYNTH_PROBE_AFTER"
create_clock -name clk -period 8.000 [get_ports clk]
report_clocks -file [file join $out clocks_synth.txt]
report_utilization -file [file join $out utilization_synth.txt]
report_utilization -hierarchical -file [file join $out utilization_hierarchical_synth.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_synth.txt]
write_checkpoint -force [file join $out cnn_top_synth.dcp]
exit
