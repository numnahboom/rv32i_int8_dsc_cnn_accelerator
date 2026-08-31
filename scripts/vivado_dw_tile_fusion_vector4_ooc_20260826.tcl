set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_dw_tile_fusion_vector4_ooc_20260826]]
file mkdir $out
set files [list \
    rtl/common/round_shift.v rtl/common/saturate_int8.v rtl/common/requant_activation_core.v \
    rtl/cnn/requant_activation_unit.v rtl/cnn/requant_activation_vector4.v \
    rtl/cnn/requant_activation_stream4.v \
    rtl/cnn/dw_line_buffer.v rtl/cnn/dw_mac_lanes.v rtl/cnn/dw_tile_fusion_engine_vector4.v]
foreach f $files { read_verilog -sv [file join $root $f] }
synth_design -top dw_tile_fusion_engine_vector4 -part xc7z020clg400-1 \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -period 8.000 -name clk [get_ports clk]
place_design
route_design
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $out timing_summary.txt]
report_utilization -file [file join $out utilization.txt]
report_route_status -file [file join $out route_status.txt]
report_power -file [file join $out power.txt]
report_drc -file [file join $out drc.txt]
write_checkpoint -force [file join $out dw_tile_fusion_vector4_ooc.dcp]
exit
