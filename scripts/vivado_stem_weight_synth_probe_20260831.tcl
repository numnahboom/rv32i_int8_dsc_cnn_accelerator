set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_stem_weight_synth_probe_20260831]]
file mkdir $out
set_param general.maxThreads 1
set part xc7z020clg400-1
read_verilog -sv [file join $root rtl common requant_activation_core.v]
read_verilog -sv [file join $root rtl cnn requant_activation_unit.v]
read_verilog -sv [file join $root rtl cnn stem_weight_store_packed64.v]
read_verilog -sv [file join $root rtl cnn stem_unified64_streaming.v]
puts "PROBE_BEFORE_SYNTH"
synth_design -top stem_static_window_banks -part $part -flatten_hierarchy none \
    -directive AreaOptimized_high
puts "PROBE_AFTER_SYNTH"
create_clock -name clk -period 8.000 [get_ports clk]
puts "PROBE_AFTER_CLOCK"
report_utilization -file [file join $out utilization_synth.txt]
puts "PROBE_AFTER_UTIL"
report_high_fanout_nets -max_nets 100 -file [file join $out high_fanout_synth.txt]
puts "PROBE_AFTER_FANOUT"
exit
