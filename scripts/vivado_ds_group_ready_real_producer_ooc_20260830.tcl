# XC7Z020 8 ns OOC screen for the real-producer integration shell.
# This is not cnn_top/full-net timing closure.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_group_ready_real_producer_ooc_20260830]]
file mkdir $out
set part xc7z020clg400-1
foreach f {
    rtl/cnn/systolic_pe.v
    rtl/cnn/pw_systolic_array_8x8.v
    rtl/cnn/ds_group_ready_half_assembler.v
    rtl/cnn/ds_group_ready_scratch_bank.v
    rtl/cnn/ds_group_ready_partial_k_pipeline.v
    rtl/cnn/ds_spatial_word_window_bank.v
    rtl/cnn/ds_word_window_fill_engine.v
    rtl/cnn/ds_word_window_pingpong_shell.v
    rtl/cnn/dw_direct_3x3_dsp.v
    rtl/cnn/dw_direct_3x3_dsp_prefetched.v
    rtl/cnn/dw_direct_3x3_dsp_quadlocal.v
    rtl/cnn/ds_word_window_dw_producer_island.v
    rtl/cnn/requant_activation_unit.v
    rtl/cnn/requant_activation_stream4.v
    rtl/cnn/requant_activation_stream4_masked.v
    rtl/cnn/ds_dw_requant_stream4_write_adapter.v
    rtl/cnn/ds_dw_requant_stream4_write_adapter_local.v
    rtl/cnn/ds_pw_spatial_tile_bank_tagless.v
    rtl/cnn/ds_word_window_dw_tagless_stream4_pipeline.v
    rtl/cnn/ds_word_window_dw_tagless_stream4_4x8.v
    rtl/cnn/ds_group_ready_real_producer.v
} { read_verilog -sv [file join $root $f] }
synth_design -top ds_group_ready_real_producer -part $part \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
place_design
route_design
report_timing_summary -delay_type min_max -max_paths 100 \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_group_ready_real_producer_ooc_post_route.dcp]
exit
