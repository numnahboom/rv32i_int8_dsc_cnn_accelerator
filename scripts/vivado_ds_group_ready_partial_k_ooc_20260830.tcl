# 8 ns routed OOC screen for the group-ready partial-K DS integration island.
# This is not a cnn_top/full-net acceptance run.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_group_ready_partial_k_ooc_20260830]]
file mkdir $out
set part xc7z020clg400-1

read_verilog -sv [file join $root rtl cnn systolic_pe.v]
read_verilog -sv [file join $root rtl cnn pw_systolic_array_8x8.v]
read_verilog -sv [file join $root rtl cnn ds_group_ready_half_assembler.v]
read_verilog -sv [file join $root rtl cnn ds_group_ready_scratch_bank.v]
read_verilog -sv [file join $root rtl cnn ds_group_ready_partial_k_pipeline.v]
synth_design -top ds_group_ready_partial_k_pipeline -part $part \
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
write_checkpoint -force [file join $out ds_group_ready_partial_k_ooc_post_route.dcp]
exit
