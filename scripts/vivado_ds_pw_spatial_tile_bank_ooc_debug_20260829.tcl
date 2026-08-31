set root [file normalize [file join [file dirname [info script]] ..]]
set_param general.maxThreads 1
read_verilog -sv {D:/Software/vivado2025.2/2025.2/Vivado/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv}
read_verilog -sv [file join $root rtl cnn ds_pw_spatial_tile_bank.v]
synth_design -top ds_pw_spatial_tile_bank -part xc7z020clg400-1 -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period 8.000 [get_ports clk]
opt_design
place_design
route_design
report_timing_summary -delay_type min_max -max_paths 20 -file [file join $root build bank_debug_timing.txt]
report_utilization -file [file join $root build bank_debug_util.txt]
exit
