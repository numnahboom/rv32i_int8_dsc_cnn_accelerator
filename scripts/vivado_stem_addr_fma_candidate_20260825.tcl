# Isolated, fresh 8 ns screen for the ADDR->F->M->A stem candidate.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_stem_addr_fma_candidate_20260825_retry3]]
file mkdir $out
set part xc7z020clg400-1
set rtl [file join $root rtl cnn conv3x3_stem_engine_new.v]
set fh [open [file join $out manifest.txt] w]
puts $fh "date [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %z}]"
puts $fh "rtl $rtl"
puts $fh "rtl_sha256 [exec powershell -NoProfile -Command \"(Get-FileHash -Algorithm SHA256 -LiteralPath '$rtl').Hash\"]"
close $fh
read_verilog -sv $rtl
synth_design -top conv3x3_stem_engine_new -part $part -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
write_checkpoint -force [file join $out candidate_synth.dcp]
create_clock -period 8.000 -name clk [get_ports clk]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -delay_type max -file [file join $out timing_summary_post_route.txt]
report_timing_summary -delay_type min -file [file join $out timing_hold_summary_post_route.txt]
report_timing -delay_type max -max_paths 200 -file [file join $out timing_maxpaths_post_route.txt]
report_timing -delay_type min -max_paths 200 -file [file join $out timing_minpaths_post_route.txt]
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
write_checkpoint -force [file join $out candidate_post_route.dcp]

# Resolve each cone from the opened post-route DCP.  Do not issue a timing
# query with an empty/stale pattern: absence is an explicit gate failure.
proc pins_or_fail {label pattern direction} {
    set pins [get_pins -hier -filter $pattern]
    if {[llength $pins] == 0} { error "TARGET_MISSING $label direction=$direction pattern={$pattern}" }
    return $pins
}
proc cone {out name from_pattern to_pattern} {
    set from [pins_or_fail "${name}_from" $from_pattern from]
    set to [pins_or_fail "${name}_to" $to_pattern to]
    set fh [open [file join $out "${name}_objects.txt"] w]
    puts $fh "FROM $from"; puts $fh "TO $to"; close $fh
    report_timing -delay_type max -from $from -to $to -max_paths 20 -file [file join $out "${name}_max.txt"]
    report_timing -delay_type min -from $from -to $to -max_paths 20 -file [file join $out "${name}_min.txt"]
}
set addr_from {NAME =~ *rd_input_addr_reg*/Q || NAME =~ *rd_weight_addr_reg*/Q}
set operand_to {NAME =~ *operand_input_?*/D || NAME =~ *operand_weight_?*/D}
set operand_from {NAME =~ *operand_input_?*/Q || NAME =~ *operand_weight_?*/Q}
set product_to {NAME =~ *product_reg_?*/D}
set product_from {NAME =~ *product_reg_?*/Q}
set lane_to {NAME =~ *lane_reg_?*/D}
set lane_from {NAME =~ *lane_reg_?*/Q}
set pair_to {NAME =~ *pair_reg*/D}
set pair_from {NAME =~ *pair_reg*/Q}
set total_to {NAME =~ *total_reg*/D}
set total_from {NAME =~ *total_reg*/Q}
cone $out addr_to_operand $addr_from $operand_to
cone $out operand_to_product $operand_from $product_to
cone $out product_to_lane $product_from $lane_to
cone $out lane_feedback $lane_from $lane_to
cone $out lane_to_pair $lane_from $pair_to
cone $out pair_to_total $pair_from $total_to
cone $out total_bias_to_sum {NAME =~ *total_reg*/Q || NAME =~ *bias_mem_reg*/Q} {NAME =~ *rq_sum_reg*/D}
set fh [open [file join $out target_cells.txt] w]
foreach pat {*rd_input_addr_reg* *rd_weight_addr_reg* *operand_input* *operand_weight* *product_reg* *lane_reg* *pair_reg* *total_reg* *DSP48*} {
    set cells [get_cells -hier -filter "NAME =~ $pat"]
    puts $fh "PATTERN $pat"
    foreach c $cells { puts $fh "$c REF=[get_property REF_NAME $c]" }
}
close $fh
puts "SCREEN_OUTPUT $out"
exit
