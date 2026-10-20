# Compare default and explicit synchronous-reset inference in the installed DC.
set root [file normalize [file join [file dirname [info script]] ..]]
set preserve 0
if {[info exists ::env(D4_PRESERVE_SYNC_RESET)]} {set preserve $::env(D4_PRESERVE_SYNC_RESET)}
if {$preserve} {set_app_var hdlin_ff_always_sync_set_reset true}
set db /opt/pdk/smic0.18um/DigitalIC/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db
set_app_var target_library [list $db]
set_app_var link_library [list * $db]
file mkdir WORK
define_design_lib WORK -path WORK
analyze -format sverilog $root/rtl/asic/d4_sync_reset_probe.sv
elaborate d4_sync_reset_probe
link
create_clock -period 10 [get_ports clk]
compile_ultra -no_autoungroup
write -format verilog -hierarchy -output mapped.v
redirect area.rpt {report_area}
puts "D4_SYNC_RESET_SYNTH_DONE preserve=$preserve"
quit
