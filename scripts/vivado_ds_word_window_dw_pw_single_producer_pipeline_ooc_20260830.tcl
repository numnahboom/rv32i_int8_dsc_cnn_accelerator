set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_word_window_dw_pw_single_producer_pipeline_ooc_20260830]]
file mkdir $out
set_param general.maxThreads 2
read_verilog -sv {D:/Software/vivado2025.2/2025.2/Vivado/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}
read_verilog -sv \
  [file join $root rtl cnn requant_activation_unit.v] \
  [file join $root rtl common requant_activation_core.v] \
  [file join $root rtl cnn requant_activation_stream2.v] \
  [file join $root rtl cnn requant_activation_row2.v] \
  [file join $root rtl cnn ds_spatial_word_window_bank.v] \
  [file join $root rtl cnn ds_word_window_fill_engine.v] \
  [file join $root rtl cnn ds_word_window_pingpong_shell.v] \
  [file join $root rtl cnn dw_direct_3x3_dsp.v] \
  [file join $root rtl cnn dw_direct_3x3_dsp_prefetched.v] \
  [file join $root rtl cnn ds_word_window_dw_producer_island.v] \
  [file join $root rtl cnn ds_dw_requant_stream4_write_adapter_local.v] \
  [file join $root rtl cnn pw_direct_8x8_dsp_rowbank.v] \
  [file join $root rtl cnn pw_packed_rowstore_feeder.v] \
  [file join $root rtl cnn dw_pw_pair_scratch_bank.v] \
  [file join $root rtl cnn dw_pw_pair_scratch_rowbank2_packed_consumer.v] \
  [file join $root rtl cnn row_image_bram_store.v] \
  [file join $root rtl cnn ds_word_window_dw_pw_single_producer_pipeline.v]
synth_design -top ds_word_window_dw_pw_single_producer_pipeline -part xc7z020clg400-1 \
  -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized \
  -generic MAX_CIN=8 -generic MAX_COUT=8 -generic MAX_GROUPS=16 \
  -generic MAX_IN_H=10 -generic MAX_IN_W=10 -generic FIFO_DEPTH=2
report_utilization -hierarchical -file [file join $out utilization_post_synth.txt]
report_high_fanout_nets -max_nets 200 -file [file join $out high_fanout_post_synth.txt]
create_clock -name clk -period 8.000 [get_ports clk]
place_design
phys_opt_design -directive AggressiveExplore
route_design
report_timing_summary -delay_type min_max -max_paths 100 -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_word_window_dw_pw_single_producer_pipeline_ooc_post_route.dcp]
exit
