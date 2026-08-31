# Standalone XC7Z020 OOC timing screen for the PW operand-staging candidate
# through the memory-oriented DS block.  This is not a cnn_top run.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_block_tile_engine_operand_pipeline_ooc_20260828]]
file mkdir $out
set files [list \
    rtl/common/round_shift.v rtl/common/saturate_int8.v rtl/common/requant_activation_core.v \
    rtl/cnn/requant_activation_unit.v rtl/cnn/requant_activation_vector4.v \
    rtl/cnn/requant_activation_stream4.v \
    rtl/cnn/systolic_pe.v rtl/cnn/pw_systolic_array_8x8.v \
    rtl/cnn/dw_line_buffer.v rtl/cnn/dw_mac_lanes.v rtl/cnn/dw_tile_buffer_bram.v \
    rtl/cnn/ds_input_tile_buffer_bram.v rtl/cnn/pw_weight_buffer_bram.v \
    rtl/cnn/dw_tile_fusion_engine_vector4.v rtl/cnn/ds_block_tile_engine_new.v]
foreach f $files { read_verilog -sv [file join $root $f] }
synth_design -top ds_block_tile_engine_new -part xc7z020clg400-1 \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 10.000 [get_ports clk]
place_design
route_design
report_timing_summary -delay_type min_max -max_paths 50 \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 100 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 100 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_block_tile_engine_operand_pipeline_ooc_post_route.dcp]
exit
