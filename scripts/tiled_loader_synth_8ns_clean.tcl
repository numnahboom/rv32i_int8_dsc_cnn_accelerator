set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports tiled_loader_synth_8ns_clean]]
file mkdir $out
set files [list \
rtl/common/round_shift.v rtl/common/saturate_int8.v rtl/common/requant_activation_core.v \
rtl/cnn/requant_activation_unit.v rtl/cnn/requant_activation_pipeline.v rtl/cnn/requant_product_pipeline.v \
rtl/cnn/requant_activation_vector4.v \
rtl/cnn/systolic_pe.v rtl/cnn/pw_systolic_array_8x8.v rtl/cnn/dw_line_buffer.v rtl/cnn/dw_mac_lanes.v \
rtl/cnn/dw_tile_buffer_bram.v rtl/cnn/ds_input_tile_buffer_bram.v rtl/cnn/pw_weight_buffer_bram.v \
rtl/cnn/dw_tile_fusion_engine_new.v rtl/cnn/ds_block_tile_engine_new.v rtl/cnn/conv3x3_stem_engine_new.v \
rtl/cnn/gap_unit_new.v rtl/cnn/fc_unit_new.v rtl/cnn/tile_scheduler.v rtl/cnn/feature_sram_bank.v \
rtl/cnn/feature_sram_pingpong.v rtl/cnn/status_counter.v rtl/cnn/descriptor_fetch.v rtl/cnn/cnn_layer_runner.v \
rtl/cnn/cnn_top_ctrl.v rtl/cnn/cnn_top.v]
foreach f $files { read_verilog -sv [file join $root $f] }
synth_design -top cnn_top -part xc7z020clg400-1 -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -period 8.000 -name clk [get_ports clk]
report_timing_summary -file [file join $out timing_summary.txt]
report_utilization -file [file join $out utilization.txt]
write_checkpoint -force [file join $out cnn_top_synth_8ns.dcp]
set f [open [file join $out cells.txt] w]
foreach c [get_cells -hier -filter {IS_SEQUENTIAL}] {
  set n [get_property NAME $c]
  if {[string match *u_layer_runner* $n]} { puts $f "$n REF=[get_property REF_NAME $c]" }
}
foreach c [get_cells -hier -filter {REF_NAME =~ DSP48*}] { puts $f "DSP $c" }
close $f
exit
