# Strict 8 ns physical screen for the non-production 4x8 word-window DW
# producer.  The wrapper fixes 4x8 output geometry and selects quad-local DW
# plus local stream4 requant islands; no runner or PW RTL is elaborated.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_word_window_dw_tagless_stream4_4x8_ooc_20260830]]
file mkdir $out
set_param general.maxThreads 2
set part xc7z020clg400-1

read_verilog -sv [file join $root rtl common requant_activation_core.v]
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn ds_dw_requant_stream4_write_adapter.v]
read_verilog -sv [file join $root rtl cnn ds_dw_requant_stream4_write_adapter_local.v]
read_verilog -sv [file join $root rtl cnn ds_pw_spatial_tile_bank_tagless.v]
read_verilog -sv [file join $root rtl cnn ds_spatial_word_window_bank.v]
read_verilog -sv [file join $root rtl cnn ds_word_window_fill_engine.v]
read_verilog -sv [file join $root rtl cnn ds_word_window_pingpong_shell.v]
read_verilog -sv [file join $root rtl cnn dw_direct_3x3_dsp.v]
read_verilog -sv [file join $root rtl cnn dw_direct_3x3_dsp_prefetched.v]
read_verilog -sv [file join $root rtl cnn dw_direct_3x3_dsp_quadlocal.v]
read_verilog -sv [file join $root rtl cnn ds_word_window_dw_producer_island.v]
read_verilog -sv [file join $root rtl cnn ds_word_window_dw_tagless_stream4_pipeline.v]
read_verilog -sv [file join $root rtl cnn ds_word_window_dw_tagless_stream4_4x8.v]
read_verilog -sv {D:/Software/vivado2025.2/2025.2/Vivado/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}

synth_design -top ds_word_window_dw_tagless_stream4_4x8 -part $part \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized \
    -generic MAX_IN_H=17 -generic MAX_IN_W=17 -generic ADDR_WIDTH=24 \
    -generic WORD_COUNT_WIDTH=16 -generic FIFO_DEPTH=2
create_clock -name clk -period 8.000 [get_ports clk]
opt_design
place_design -directive Explore
phys_opt_design -directive AggressiveExplore
route_design

report_timing_summary -delay_type min_max -max_paths 100 \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 300 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 300 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_high_fanout_nets -timing -load_types -max_nets 200 \
    -file [file join $out high_fanout_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_word_window_dw_tagless_stream4_4x8_ooc_post_route.dcp]
exit
