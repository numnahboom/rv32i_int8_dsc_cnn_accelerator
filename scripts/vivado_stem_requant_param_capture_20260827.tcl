# Fresh isolated 8 ns OOC screen for the Stem channel-local requant
# parameter capture.  The multiplier is read in ST_RQ_SUM and registered
# before the rq_product_reg DSP write, removing channel_idx from that DSP
# input path while preserving the arithmetic and cycle schedule.
set root [file normalize [file join [file dirname [info script]] ..]]
set out_name vivado_stem_requant_param_capture_20260827
if {[info exists ::env(STEM_OOC_OUT)]} { set out_name $::env(STEM_OOC_OUT) }
set out [file normalize [file join $root build reports $out_name]]
file mkdir $out
set part xc7z020clg400-1
set rtl [file join $root rtl cnn conv3x3_stem_engine_new.v]
if {[info exists ::env(STEM_OOC_RTL)]} { set rtl [file normalize $::env(STEM_OOC_RTL)] }
set mf [open [file join $out manifest.txt] w]
puts $mf "date [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S %z}]"
puts $mf "rtl $rtl"
puts $mf "rtl_sha256 [exec powershell -NoProfile -Command \"(Get-FileHash -Algorithm SHA256 -LiteralPath '$rtl').Hash\"]"
close $mf

read_verilog -sv $rtl
synth_design -top conv3x3_stem_engine_new -part $part \
    -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized
write_checkpoint -force [file join $out stem_requant_param_capture_synth.dcp]
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
write_checkpoint -force [file join $out stem_requant_param_capture_post_route.dcp]

proc pins_matching {label re suffix} {
    set result {}
    set pin_re [format {/%s(\[[0-9]+\])?$} $suffix]
    foreach c [get_cells -hier] {
        if {[regexp -nocase $re [get_property NAME $c]]} {
            foreach p [get_pins -of_objects $c] {
                if {[regexp $pin_re [get_property NAME $p]]} {
                    lappend result $p
                }
            }
        }
    }
    if {[llength $result] == 0} { error "DISCOVERY_MISSING $label regex={$re} suffix=$suffix" }
    return $result
}
proc cone {out name from to} {
    set fh [open [file join $out "${name}_objects.txt"] w]
    puts $fh "FROM $from"
    puts $fh "TO $to"
    close $fh
    if {[catch {report_timing -delay_type max -from $from -to $to -max_paths 20 \
        -file [file join $out "${name}_max.txt"]} err]} {
        set fh [open [file join $out "${name}_max.txt"] w]
        puts $fh "NO_TIMING_PATH $err"
        close $fh
    }
    if {[catch {report_timing -delay_type min -from $from -to $to -max_paths 20 \
        -file [file join $out "${name}_min.txt"]} err]} {
        set fh [open [file join $out "${name}_min.txt"] w]
        puts $fh "NO_TIMING_PATH $err"
        close $fh
    }
}

set channel_q [pins_matching channel_q {^channel_idx_reg} Q]
set product_c [pins_matching product_c {^rq_product_reg_reg__0} C]
set f [open [file join $out discovered_groups.txt] w]
foreach {label pins} [list channel_q $channel_q product_c $product_c] {
    puts $f "GROUP $label"
    foreach p $pins { puts $f $p }
}
close $f
cone $out channel_to_product $channel_q $product_c
puts "SCREEN_OUTPUT $out"
exit
