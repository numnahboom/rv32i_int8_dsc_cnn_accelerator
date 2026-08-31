set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build reports vivado_dual32_mac_local_island_ooc_20260830]
file mkdir $out_dir
set_part xc7z020clg400-1
create_project -force dual32_mac_local_island_ooc $out_dir -part xc7z020clg400-1
set_property target_language Verilog [current_project]
read_verilog [file join $root rtl cnn dual32_mac_local_island.v]
read_verilog [file join $root rtl cnn dual32_mac_local_island_ooc_wrapper.v]
set_property top dual32_mac_local_island_ooc_wrapper [current_fileset]
update_compile_order -fileset sources_1
read_xdc [file join $out_dir dual32.xdc]
synth_design -top dual32_mac_local_island_ooc_wrapper -part xc7z020clg400-1 -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore
report_timing_summary -delay_type max -max_paths 20 -file [file join $out_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 100 -file [file join $out_dir timing_max.rpt]
report_timing -delay_type min -max_paths 100 -file [file join $out_dir timing_min.rpt]
report_utilization -file [file join $out_dir utilization.rpt]
report_power -file [file join $out_dir power.rpt]
report_high_fanout_nets -timing -load_types -max_nets 100 -file [file join $out_dir high_fanout.rpt]
write_checkpoint -force [file join $out_dir dual32_mac_local_island_ooc.dcp]
puts "DUAL32_OOC_DONE $out_dir"
