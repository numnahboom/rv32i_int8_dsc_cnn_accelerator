# 8 ns XC7Z020 exploratory screen for the complete DW/PW tile island.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_word_window_dw_pw_tile_pipeline_ooc_20260829]]
file mkdir $out
set_param general.maxThreads 1
# Vivado's standalone batch elaborator does not always preload XPM when the
# hierarchy is entered through this integration top.  Read the installed XPM
# source explicitly so the OOC run is deterministic.
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
  -generic MAX_CIN=16 -generic MAX_COUT=16 -generic MAX_IN_H=10 \
  -generic MAX_IN_W=10 -generic FIFO_DEPTH=2
create_clock -name clk -period 8.000 [get_ports clk]
# Vivado 2025.2's opt_design crashes on the vector4 requant FIFO muxes
# (Synth 20-411).  The synthesized OOC netlist is legal and can be placed and
# routed directly, matching the established vector4 acceptance flow.
place_design
phys_opt_design -directive AggressiveExplore
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
write_checkpoint -force [file join $out ds_word_window_dw_pw_tile_pipeline_ooc_post_route.dcp]
exit
