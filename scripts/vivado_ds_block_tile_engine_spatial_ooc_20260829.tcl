# Standalone 8 ns OOC screen for the experimental spatial DS scheduler.
# This does not replace or implement the production DS engine/top level.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_block_tile_engine_spatial_ooc_20260829]]
file mkdir $out
set part xc7z020clg400-1
set_param general.maxThreads 2

read_verilog -sv \
    [file join $root rtl cnn ds_block_tile_engine_spatial.v] \
    [file join $root rtl cnn dw_direct_3x3_dsp.v] \
    [file join $root rtl cnn ds_spatial_dw_producer_island.v] \
    [file join $root rtl cnn dw_pw_spatial_block_buffer_island.v] \
    [file join $root rtl cnn dw_pw_spatial_bank_bram.v] \
    [file join $root rtl cnn ds_input_tile_buffer_bram.v] \
    [file join $root rtl cnn pw_direct_8x8_dsp.v] \
    [file join $root rtl cnn ds_spatial_pw_consumer_island.v] \
    [file join $root rtl cnn requant_activation_vector4_spatial.v] \
    [file join $root rtl cnn requant_activation_unit.v]
synth_design -top ds_block_tile_engine_spatial -part $part \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
opt_design
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
write_checkpoint -force [file join $out ds_block_tile_engine_spatial_ooc_post_route.dcp]
exit
