# Fresh isolated 8 ns post-route screen for the stem ADDR/F/M/A candidate.
# All timing endpoints are discovered from this run's post-route DCP.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_stem_addr_fma_candidate_fresh_20260825]]
file mkdir $out
set part xc7z020clg400-1
set rtl [file join $root rtl cnn conv3x3_stem_engine_new.v]
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
report_utilization -file [file join $out utilization_post_route.txt]
report_route_status -file [file join $out route_status_post_route.txt]
write_checkpoint -force [file join $out candidate_post_route.dcp]

proc seq_cells {re} {
    set r {}
    foreach c [get_cells -hier -filter {IS_SEQUENTIAL}] {
        if {[regexp -nocase $re [get_property NAME $c]]} { lappend r $c }
    }
    return $r
}
proc pins_dir {cells dir} {
    set r {}
    foreach c $cells {
        foreach p [get_pins -of_objects $c] {
            if {[regexp "/${dir}$" [get_property NAME $p]]} { lappend r $p }
        }
    }
    return $r
}
proc must {label objs} {
    if {[llength $objs] == 0} { error "DISCOVERY_MISSING $label" }
    return $objs
}
proc write_objects {out name from to} {
    set f [open [file join $out "${name}_objects.txt"] w]
    puts $f "FROM $from"
    puts $f "TO $to"
    close $f
}
proc cone {out name from to} {
    set from [list {*}$from]
    set to [list {*}$to]
    write_objects $out $name $from $to
    report_timing -delay_type max -from $from -to $to -max_paths 20 -file [file join $out "${name}_max.txt"]
    report_timing -delay_type min -from $from -to $to -max_paths 20 -file [file join $out "${name}_min.txt"]
}

# Synthesis may add bit indices to these names; discovery deliberately uses
# the stable RTL stem rather than hard-coded cell/pin endpoints.
set cursor [must cursor [seq_cells {(input|weight)_addr_cursor_reg}]]
set addr [must addr [seq_cells {rd_(input|weight)_addr_reg}]]
set operand [must operand [seq_cells {operand_(input|weight)}]]
set product [must product [seq_cells {product_reg_[012]_reg}]]
set lane [must lane [seq_cells {lane_reg_[012]_reg}]]
set pair [must pair [seq_cells {pair_reg_reg}]]
set total [must total [seq_cells {total_reg_reg}]]
set cursor_q [must cursor_q [pins_dir $cursor Q]]
set addr_d [must addr_d [pins_dir $addr D]]
set addr_q [must addr_q [pins_dir $addr Q]]
set operand_d [must operand_d [pins_dir $operand D]]
set operand_q [must operand_q [pins_dir $operand Q]]
set product_d [must product_d [pins_dir $product D]]
set product_q [must product_q [pins_dir $product Q]]
set lane_d [must lane_d [pins_dir $lane D]]
set lane_q [must lane_q [pins_dir $lane Q]]
set pair_d [must pair_d [pins_dir $pair D]]
set pair_q [must pair_q [pins_dir $pair Q]]
set total_d [must total_d [pins_dir $total D]]
set total_q [must total_q [pins_dir $total Q]]

set f [open [file join $out discovered_groups.txt] w]
foreach {label cells} [list cursor $cursor addr $addr operand $operand product $product lane $lane pair $pair total $total] {
    puts $f "GROUP $label"
    foreach c $cells { puts $f "$c REF=[get_property REF_NAME $c]" }
}
close $f

# Required registered cones plus a scalar bypass audit from address Q to lane D.
cone $out cursor_to_rd_addr $cursor_q $addr_d
cone $out rd_addr_to_operand $addr_q $operand_d
cone $out operand_to_product $operand_q $product_d
cone $out product_to_lane $product_q $lane_d
cone $out lane_feedback $lane_q $lane_d
cone $out lane_to_pair $lane_q $pair_d
cone $out pair_to_total $pair_q $total_d
cone $out addr_to_lane_bypass $addr_q $lane_d

# Audit total+bias into the actual post-route DSP input pins.  Bias storage is
# optional after optimization; total Q is mandatory and the discovered bias Q
# pins are included when present.  The DSP pin set is discovered from REF_NAME.
set bias {}
foreach c [get_cells -hier -filter {IS_SEQUENTIAL}] {
    if {[regexp -nocase {bias_mem|bias_reg} [get_property NAME $c]]} {
        foreach p [get_pins -of_objects $c] {
            if {[regexp {/Q$} [get_property NAME $p]]} { lappend bias $p }
        }
    }
}
set dsp_inputs {}
foreach c [get_cells -hier -filter {REF_NAME == DSP48E1}] {
    foreach p [get_pins -of_objects $c] {
        set pn [get_property REF_PIN_NAME $p]
        if {[regexp {^(A|B|C|D|AD|INMODE|OPMODE|ALUMODE|CARRYIN|MULTSIGNIN)} $pn]} {
            lappend dsp_inputs $p
        }
    }
}
set dsp_inputs [must dsp_inputs $dsp_inputs]
set bias_sources [concat $total_q $bias]
write_objects $out total_bias_to_dsp_input $bias_sources $dsp_inputs
report_timing -delay_type max -from $bias_sources -to $dsp_inputs -max_paths 50 -file [file join $out total_bias_to_dsp_input_max.txt]
report_timing -delay_type min -from $bias_sources -to $dsp_inputs -max_paths 50 -file [file join $out total_bias_to_dsp_input_min.txt]
set f [open [file join $out discovered_dsp_inputs.txt] w]
foreach p $dsp_inputs { puts $f "$p REF_PIN_NAME=[get_property REF_PIN_NAME $p]" }
close $f
puts "SCREEN_OUTPUT $out"
exit
