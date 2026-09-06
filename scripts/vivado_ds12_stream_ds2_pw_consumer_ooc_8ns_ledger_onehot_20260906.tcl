# DS12 DS2 PW consumer: explicit per-entry one-hot ledger OOC closure run.
#
# The synthesis gate is intentionally before place/route.  It requires the
# four banks to contain 32 retained entry instances and rejects the old
# dynamic slot_epoch register naming.  The run uses the same 8 ns clock and
# no timing exceptions as the prior ledger baseline.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_onehot_20260906]]
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
puts $settings_file "flatten_hierarchy=none"
puts $settings_file "place_directive=Explore"
puts $settings_file "phys_opt_directive=Explore"
puts $settings_file "route_directive=Explore"
puts $settings_file "clock_period_ns=$clock_period_ns"
puts $settings_file "general.maxThreads=$actual_threads"
puts $settings_file "source_filelist=[file normalize [file join [file dirname [info script]] ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.f]]"
puts $settings_file "boundary=isolated ds12_stream_ds2_pw_consumer module; not full top/network"
puts $settings_file "candidate=4x8 bank with explicit one-hot per-entry ledger and retained entry hierarchy"
puts $settings_file "timing_exceptions=none"
close $settings_file

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

puts "DS2_PW_ONEHOT_OOC_STAGE synth_start out=$out top=$top part=$part clock_period_ns=$clock_period_ns"
synth_design -top $top -part $part -flatten_hierarchy none \
    -mode out_of_context -directive RuntimeOptimized
create_clock -name clk -period $clock_period_ns [get_ports clk]
set_clock_uncertainty -setup 0.000 [get_clocks clk]
set_clock_uncertainty -hold 0.000 [get_clocks clk]

report_utilization -hierarchical -file [file join $out utilization_synth_hierarchical.rpt]
report_utilization -file [file join $out utilization_synth.rpt]
report_timing_summary -delay_type min_max -max_paths 100 -report_unconstrained \
    -file [file join $out timing_summary_synth_estimate.rpt]
write_verilog -force [file join $out post_synth_netlist.v]
write_checkpoint -force [file join $out ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_onehot_post_synth.dcp]

# Structural gate: every slot must be a retained entry instance.  The old
# dynamic-array implementation exposed slot_epoch_reg[*] and a bank-wide
# decoder; those names must not be present in the synthesized cell graph.
set gate_file [open [file join $out post_synth_structural_gate.txt] w]
set entry_cells [get_cells -hier -filter {NAME =~ "*gen_slot_entry*"}]
set old_epoch_cells [get_cells -hier -filter {NAME =~ "*slot_epoch_reg*"}]
set entry_epoch_cells [get_cells -hier -filter {NAME =~ "*gen_slot_entry*epoch_r_reg*"}]
set entry_state_cells [get_cells -hier -filter {NAME =~ "*gen_slot_entry*state_r_reg*"}]
set entry_muxf7_cells [get_cells -hier -filter {NAME =~ "*gen_slot_entry*" && REF_NAME == MUXF7}]
puts $gate_file "entry_hierarchy_cells=[llength $entry_cells]"
puts $gate_file "entry_epoch_register_cells=[llength $entry_epoch_cells]"
puts $gate_file "entry_state_register_cells=[llength $entry_state_cells]"
puts $gate_file "entry_muxf7_cells=[llength $entry_muxf7_cells]"
puts $gate_file "old_dynamic_slot_epoch_cells=[llength $old_epoch_cells]"
puts $gate_file "requirement=32 entry instances; no old slot_epoch_reg dynamic ledger"
if {[llength $entry_cells] < 32} {
    puts $gate_file "RESULT=FAIL insufficient entry hierarchy"
    close $gate_file
    error "one-hot structural gate failed: entry hierarchy count [llength $entry_cells] < 32"
}
if {[llength $old_epoch_cells] != 0} {
    puts $gate_file "RESULT=FAIL old dynamic slot_epoch register remains"
    close $gate_file
    error "one-hot structural gate failed: old slot_epoch_reg cells remain"
}

# Save focused pre-route timing reports.  They are evidence for the next
# gate; no place/route work is started until the structural checks above pass.
set epoch_c_pins [get_pins -hier -filter {NAME =~ "*gen_slot_entry*epoch_r_reg*/C"}]
set state_d_pins [get_pins -hier -filter {NAME =~ "*gen_slot_entry*state_r_reg*/D"}]
set state_ce_pins [get_pins -hier -filter {NAME =~ "*gen_slot_entry*state_r_reg*/CE"}]
puts $gate_file "epoch_c_pins=[llength $epoch_c_pins]"
puts $gate_file "state_d_pins=[llength $state_d_pins]"
puts $gate_file "state_ce_pins=[llength $state_ce_pins]"
if {[llength $epoch_c_pins] > 0 && [llength $state_d_pins] > 0} {
    report_timing -from $epoch_c_pins -to $state_d_pins -max_paths 200 \
        -file [file join $out post_synth_epoch_to_state_d_paths.rpt]
}
if {[llength $epoch_c_pins] > 0 && [llength $state_ce_pins] > 0} {
    report_timing -from $epoch_c_pins -to $state_ce_pins -max_paths 200 \
        -file [file join $out post_synth_epoch_to_state_ce_paths.rpt]
}
puts $gate_file "RESULT=PASS structural entry/old-array gate"
close $gate_file
puts "DS2_PW_ONEHOT_OOC_STAGE structural_gate_pass entries=[llength $entry_cells] epoch_regs=[llength $entry_epoch_cells] state_regs=[llength $entry_state_cells]"

place_design -directive Explore
puts "DS2_PW_ONEHOT_OOC_STAGE place_done"
phys_opt_design -directive Explore
puts "DS2_PW_ONEHOT_OOC_STAGE phys_opt_done"
route_design -directive Explore
puts "DS2_PW_ONEHOT_OOC_STAGE route_done"

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
write_checkpoint -force [file join $out ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_onehot_post_route.dcp]
puts "DS2_PW_ONEHOT_OOC_DONE out=$out top=$top general.maxThreads=$actual_threads clock_period_ns=$clock_period_ns"
exit
