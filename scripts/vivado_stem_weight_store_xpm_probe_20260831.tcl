# Isolate the XPM packed Stem weight store from the large Stem datapath.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_stem_weight_store_xpm_probe_20260831]]
file mkdir $out
set_param general.maxThreads 1
set part xc7z020clg400-1
read_verilog -sv [file join $root rtl cnn stem_weight_store_packed64.v]
puts "XPM_PROBE_BEFORE_SYNTH"
synth_design -top stem_weight_store_packed64 -part $part -mode out_of_context -directive AreaOptimized_high
puts "XPM_PROBE_AFTER_SYNTH"
report_utilization -file [file join $out utilization_synth.txt]
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_synth.txt]
exit
