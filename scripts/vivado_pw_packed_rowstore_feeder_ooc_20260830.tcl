# 8 ns XC7Z020 OOC gate for the packed 64-bit PW row-store feeder.
# This is intentionally an isolated physical screen, not a full-top claim.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_pw_packed_rowstore_feeder_ooc_20260830]]
file mkdir $out
set part xc7z020clg400-1
set_param general.maxThreads 2

read_verilog -sv [file join $root rtl common requant_activation_core.v]
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn requant_activation_stream2.v]
read_verilog -sv [file join $root rtl cnn requant_activation_row2.v]
read_verilog -sv [file join $root rtl cnn pw_direct_8x8_dsp_rowbank.v]
read_verilog -sv [file join $root rtl cnn pw_packed_rowstore_feeder.v]

synth_design -top pw_packed_rowstore_feeder -part $part \
    -generic {MAX_CIN=128 MAX_COUT=256} \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
place_design
route_design
phys_opt_design -directive AggressiveExplore

report_timing_summary -delay_type min_max -max_paths 100 \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 300 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 300 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -hierarchical -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
report_high_fanout_nets -timing -load_types -max_nets 100 \
    -file [file join $out high_fanout_nets.txt]
catch {
    report_timing -from [get_ports job_cout_base] \
        -to [get_cells -hier -filter {REF_NAME =~ RAMB*}] \
        -max_paths 50 -file [file join $out coutbase_to_weight_memory.txt]
}
catch {
    report_timing -from [get_ports job_cout_base] \
        -to [get_cells -hier -filter {REF_NAME =~ DSP*}] \
        -max_paths 50 -file [file join $out coutbase_to_dsp.txt]
}
write_checkpoint -force [file join $out pw_packed_rowstore_feeder_ooc_post_route.dcp]
exit
