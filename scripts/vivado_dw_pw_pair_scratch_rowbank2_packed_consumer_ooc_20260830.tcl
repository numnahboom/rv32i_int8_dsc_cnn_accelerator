# 8 ns XC7Z020 OOC screen for the packed-weight paired scratch consumer.
# This is an isolated physical gate, not a full-top timing claim.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_dw_pw_pair_scratch_rowbank2_packed_consumer_ooc_20260830]]
file mkdir $out
set part xc7z020clg400-1
set_param general.maxThreads 2

read_verilog -sv [file join $root rtl common requant_activation_core.v]
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn requant_activation_stream2.v]
read_verilog -sv [file join $root rtl cnn requant_activation_row2.v]
read_verilog -sv [file join $root rtl cnn pw_direct_8x8_dsp_rowbank.v]
read_verilog -sv [file join $root rtl cnn dw_pw_pair_scratch_bank.v]
read_verilog -sv [file join $root rtl cnn pw_packed_rowstore_feeder.v]
read_verilog -sv [file join $root rtl cnn dw_pw_pair_scratch_rowbank2_packed_consumer.v]

synth_design -top dw_pw_pair_scratch_rowbank2_packed_consumer -part $part \
    -generic {MAX_CIN=128 MAX_COUT=256 MAX_GROUPS=16} \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
place_design -directive Explore
route_design -directive Explore
phys_opt_design -directive AggressiveFanoutOpt

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
write_checkpoint -force [file join $out dw_pw_pair_scratch_rowbank2_packed_consumer_ooc_post_route.dcp]
exit
