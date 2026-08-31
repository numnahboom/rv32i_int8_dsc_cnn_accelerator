set root [file normalize [file join [file dirname [info script]] ..]]
set_param general.maxThreads 1
read_verilog -sv {D:/Software/vivado2025.2/2025.2/Vivado/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}
read_verilog -sv \
  [file join $root rtl cnn requant_activation_unit.v] \
  [file join $root rtl cnn requant_activation_vector4_spatial.v] \
  [file join $root rtl cnn pw_direct_8x8_dsp.v] \
  [file join $root rtl cnn dw_direct_3x3_dsp.v] \
  [file join $root rtl cnn dw_direct_3x3_dsp_prefetched.v] \
  [file join $root rtl cnn ds_word_window_fill_engine.v] \
  [file join $root rtl cnn ds_spatial_word_window_bank.v] \
  [file join $root rtl cnn ds_word_window_pingpong_shell.v] \
  [file join $root rtl cnn ds_word_window_dw_producer_island.v] \
  [file join $root rtl cnn ds_dw_requant_write_sink.v] \
  [file join $root rtl cnn ds_pw_spatial_tile_bank.v] \
  [file join $root rtl cnn ds_word_window_dw_pw_tile_pipeline.v]
synth_design -top ds_word_window_dw_pw_tile_pipeline -part xc7z020clg400-1 \
  -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized \
  -generic MAX_CIN=8 -generic MAX_COUT=8 -generic MAX_IN_H=10 \
  -generic MAX_IN_W=10 -generic FIFO_DEPTH=2
report_utilization -file [file join $root build pipeline_synth_only_util.txt]
write_checkpoint -force [file join $root build pipeline_synth_only.dcp]
exit
