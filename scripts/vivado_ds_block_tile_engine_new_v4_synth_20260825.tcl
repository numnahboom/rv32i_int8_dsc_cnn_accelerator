set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_block_tile_engine_new_v4_20260825]]
file mkdir $out
set files [list \
    rtl/common/round_shift.v rtl/common/saturate_int8.v rtl/common/requant_activation_core.v \
    rtl/cnn/requant_activation_unit.v rtl/cnn/requant_activation_vector4.v \
    rtl/cnn/requant_activation_pipeline.v rtl/cnn/requant_product_pipeline.v \
    rtl/cnn/systolic_pe.v rtl/cnn/pw_systolic_array_8x8.v rtl/cnn/dw_line_buffer.v \
    rtl/cnn/dw_mac_lanes.v rtl/cnn/dw_tile_buffer_bram.v rtl/cnn/ds_input_tile_buffer_bram.v \
    rtl/cnn/pw_weight_buffer_bram.v rtl/cnn/dw_tile_fusion_engine_new.v \
    rtl/cnn/ds_block_tile_engine_new.v]
foreach f $files { read_verilog -sv [file join $root $f] }
synth_design -top ds_block_tile_engine_new -part xc7z020clg400-1 \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
report_utilization -file [file join $out utilization.txt]
report_utilization -hierarchical -file [file join $out utilization_hierarchical.txt]
report_timing_summary -file [file join $out timing_summary.txt]
report_clock_utilization -file [file join $out clock_utilization.txt]
write_checkpoint -force [file join $out ds_block_tile_engine_new_v4_synth.dcp]
exit
