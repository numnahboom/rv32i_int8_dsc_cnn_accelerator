# DS12 DS2 PW consumer: complete XC7Z020 8 ns isolated OOC physical screen
# for the synchronous weight-BRAM prefetch candidate.
# This is a module OOC boundary, not a runner, full-top, full-network, power,
# energy, or hardware-closure result.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_weight_bram_20260906]]
file mkdir $out

set part xc7z020clg400-1
set top ds12_stream_ds2_pw_consumer
set clock_period_ns 8.000
set requested_threads 8
set_param general.maxThreads $requested_threads
set actual_threads [get_param general.maxThreads]
if {$actual_threads != $requested_threads} {
    error "general.maxThreads did not take effect: requested=$requested_threads actual=$actual_threads"
}

set settings_file [open [file join $out run_settings.txt] w]
puts $settings_file "tool=Vivado 2025.2"
puts $settings_file "part=$part"
puts $settings_file "top=$top"
puts $settings_file "mode=complete OOC synth/place/phys_opt/route"
puts $settings_file "synth_mode=out_of_context"
puts $settings_file "synth_directive=RuntimeOptimized"
puts $settings_file "place_directive=Explore"
puts $settings_file "phys_opt_directive=Explore"
puts $settings_file "route_directive=Explore"
puts $settings_file "clock_period_ns=$clock_period_ns"
puts $settings_file "general.maxThreads=$actual_threads"
puts $settings_file "source_filelist=[file normalize [file join [file dirname [info script]] ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.f]]"
puts $settings_file "boundary=isolated ds12_stream_ds2_pw_consumer module; not full top/network"
close $settings_file

# Read the dedicated manifest so the exact source cone is recorded and checked
# before synthesis. Relative paths are resolved from the repository root.
set manifest [file normalize [file join [file dirname [info script]] ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.f]]
if {![file exists $manifest]} { error "missing source manifest: $manifest" }
set mf_in [open $manifest r]
set mf_out [open [file join $out source_manifest.txt] w]
set source_count 0
while {[gets $mf_in line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} { continue }
    set p [file normalize [file join $root $line]]
    if {![file exists $p]} { error "missing RTL source: $p" }
    puts $mf_out $p
    read_verilog -sv $p
    incr source_count
}
close $mf_in
close $mf_out
if {$source_count != 1} { error "expected exactly one direct RTL source, got $source_count" }

puts "DS2_PW_OOC_STAGE synth_start out=$out top=$top part=$part clock_period_ns=$clock_period_ns"
synth_design -top $top -part $part -flatten_hierarchy none \
    -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period $clock_period_ns [get_ports clk]
set_clock_uncertainty -setup 0.000 [get_clocks clk]
set_clock_uncertainty -hold 0.000 [get_clocks clk]
report_utilization -hierarchical -file [file join $out utilization_synth_hierarchical.rpt]
report_utilization -file [file join $out utilization_synth.rpt]
report_timing_summary -delay_type min_max -max_paths 100 -report_unconstrained \
    -file [file join $out timing_summary_synth_estimate.rpt]
write_checkpoint -force [file join $out ds12_stream_ds2_pw_consumer_ooc_8ns_post_synth.dcp]
puts "DS2_PW_OOC_STAGE synth_done"

place_design -directive Explore
puts "DS2_PW_OOC_STAGE place_done"
phys_opt_design -directive Explore
puts "DS2_PW_OOC_STAGE phys_opt_done"
route_design -directive Explore
puts "DS2_PW_OOC_STAGE route_done"

report_timing_summary -delay_type min_max -max_paths 100 -report_unconstrained \
    -file [file join $out timing_summary_post_route.txt]
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_maxpaths.txt]
report_timing -delay_type min -from [all_registers] -to [all_registers] \
    -max_paths 200 -file [file join $out reg_to_reg_minpaths.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
report_design_analysis -congestion -file [file join $out congestion_post_route.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_post_route.txt]
report_drc -file [file join $out drc_post_route.txt]
write_checkpoint -force [file join $out ds12_stream_ds2_pw_consumer_ooc_8ns_post_route.dcp]
puts "DS2_PW_OOC_DONE out=$out top=$top part=$part general.maxThreads=$actual_threads clock_period_ns=$clock_period_ns"
exit
