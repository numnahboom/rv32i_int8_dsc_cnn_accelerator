# Routed OOC follow-up from the current packed-memory bridge synth DCP.
# This is the real six-shape bridge boundary, not cnn_top/full-top closure.
set root [file normalize [file join [file dirname [info script]] ..]]
set synth_out [file normalize [file join $root build reports vivado_ds_group_published_shared64_runner_adapter_synth_20260903]]
set out [file normalize [file join $root build reports vivado_ds_group_published_shared64_runner_adapter_route_20260903]]
file mkdir $out
set_param general.maxThreads 8
set requested_threads 8
set actual_threads [get_param general.maxThreads]
if {$actual_threads != $requested_threads} {
    error "general.maxThreads did not take effect: requested=$requested_threads actual=$actual_threads"
}

set sf [open [file join $out run_settings.txt] w]
puts $sf "tool=Vivado 2025.2"
puts $sf "part=xc7z020clg400-1"
puts $sf "top=ds_group_published_shared64_runner_adapter"
puts $sf "source_dcp=[file join $synth_out ds_group_published_shared64_runner_adapter_synth.dcp]"
puts $sf "clock_period_ns=8.000"
puts $sf "general.maxThreads=$actual_threads"
puts $sf "implementation=opt/place/phys_opt/route OOC"
puts $sf "place_directive=Explore"
puts $sf "phys_opt_directive=Explore"
puts $sf "route_directive=Explore"
puts $sf "boundary=real six-shape group-published runner adapter; not full top"
close $sf

open_checkpoint [file join $synth_out ds_group_published_shared64_runner_adapter_synth.dcp]
set clocks [get_clocks clk]
if {[llength $clocks] == 0} {
    create_clock -name clk -period 8.000 [get_ports clk]
} else {
    set current_period [get_property PERIOD $clocks]
    if {$current_period != 8.000} {
        error "synth DCP clock period is not 8 ns: $current_period"
    }
}
opt_design -directive Explore
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore

report_timing_summary -delay_type min_max -max_paths 100 \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_timing -delay_type max -max_paths 100 -sort_by group \
    -file [file join $out critical_paths_max.txt]
report_utilization -hierarchical -file [file join $out utilization_post_route_hier.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_design_analysis -congestion -file [file join $out congestion_post_route.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_post_route.txt]
report_clock_utilization -file [file join $out clock_utilization_post_route.txt]
report_power -file [file join $out power_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds_group_published_shared64_runner_adapter_ooc_post_route.dcp]
puts "GROUP_PUBLISHED_RUNNER_ADAPTER_ROUTE_DONE out=$out general.maxThreads=$actual_threads clock_period_ns=8.000"
exit
