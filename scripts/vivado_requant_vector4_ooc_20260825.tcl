set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_requant_vector4_ooc_20260825]]
file mkdir $out
set_part xc7z020clg400-1
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn requant_activation_vector4.v]
read_verilog -sv [file join $root rtl cnn requant_activation_vector4_ooc_wrapper.v]
synth_design -top requant_activation_vector4_ooc_wrapper -part xc7z020clg400-1 \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -period 8.000 -name clk [get_ports clk]
# The vector wrapper's generated FIFO muxes trigger Vivado 2025.2's opaque
# Synth 20-411 during standalone opt_design; placement/route can consume the
# legal OOC synthesized netlist directly and still produce full timing data.
place_design
route_design
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $out timing_summary.txt]
report_utilization -file [file join $out utilization.txt]
report_route_status -file [file join $out route_status.txt]
report_power -file [file join $out power.txt]
report_drc -file [file join $out drc.txt]
write_checkpoint -force [file join $out requant_activation_vector4_ooc.dcp]
exit
