# DS2 4x8 banked baseline: pure physical post-synthesis-DCP closure screen.
#
# Every recipe below opens the same historical banked post-synthesis DCP.  No
# RTL/TB/source is read, no timing exceptions are added, and no onehot DCP is
# accepted.  This is an isolated module/OOC experiment, not full-top closure.

set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_phys_dcp_20260906]]
set baseline_out [file normalize [file join $root build reports vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906]]
set baseline_dcp [file normalize [file join $baseline_out ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_post_synth.dcp]]
set baseline_settings [file normalize [file join $baseline_out run_settings.txt]]

set part xc7z020clg400-1
set top ds12_stream_ds2_pw_consumer
set clock_name clk
set clock_period_ns 8.000
set requested_threads 8

if {![file exists $baseline_dcp]} {
    error "missing immutable banked baseline post-synth DCP: $baseline_dcp"
}
if {[string match -nocase *onehot* $baseline_dcp]} {
    error "refusing onehot DCP input: $baseline_dcp"
}
if {![file exists $baseline_settings]} {
    error "missing historical banked baseline settings: $baseline_settings"
}
file mkdir $out

set_param general.maxThreads $requested_threads
set actual_threads [get_param general.maxThreads]
if {$actual_threads != $requested_threads} {
    error "general.maxThreads did not take effect: requested=$requested_threads actual=$actual_threads"
}

proc read_text {path} {
    set f [open $path r]
    set text [read $f]
    close $f
    return $text
}

proc write_text {path text} {
    set f [open $path w]
    puts -nonewline $f $text
    close $f
}

proc prop_or_na {obj prop} {
    if {[catch {set value [get_property $prop $obj]}]} {
        return UNSUPPORTED
    }
    if {$value eq ""} {
        return NA
    }
    return $value
}

proc number_or_na {value} {
    if {$value eq ""} { return NA }
    return [string trim $value]
}

proc parse_timing_summary {path} {
    set text [read_text $path]
    set wns NA
    set tns NA
    set whs NA
    set ths NA
    regexp -nocase {Setup\s*:\s*[0-9,]+\s+Failing Endpoints,\s+Worst Slack\s+([+-]?[0-9.]+)ns,\s+Total Violation\s+([+-]?[0-9.]+)ns} $text -> wns tns
    regexp -nocase {Hold\s*:\s*[0-9,]+\s+Failing Endpoints,\s+Worst Slack\s+([+-]?[0-9.]+)ns,\s+Total Violation\s+([+-]?[0-9.]+)ns} $text -> whs ths
    return [list [number_or_na $wns] [number_or_na $tns] [number_or_na $whs] [number_or_na $ths]]
}

proc parse_route_status {path} {
    set text [read_text $path]
    set routable NA
    set fully NA
    set errors NA
    regexp {# of routable nets\.*\s*:\s*([0-9,]+)} $text -> routable
    regexp {# of fully routed nets\.*\s*:\s*([0-9,]+)} $text -> fully
    regexp {# of nets with routing errors\.*\s*:\s*([0-9,]+)} $text -> errors
    set routable [string map {, {}} $routable]
    set fully [string map {, {}} $fully]
    set errors [string map {, {}} $errors]
    set complete [expr {$routable ne "NA" && $fully ne "NA" && $errors ne "NA" && $routable == $fully && $errors == 0}]
    return [list $complete $routable $fully $errors]
}

proc parse_utilization {path} {
    set text [read_text $path]
    set lut NA
    set ff NA
    set bram NA
    set dsp NA
    regexp {\|\s*Slice LUTs\s*\|\s*([0-9,]+)\s*\|} $text -> lut
    regexp {\|\s*Slice Registers\s*\|\s*([0-9,]+)\s*\|} $text -> ff
    regexp {\|\s*Block RAM Tile\s*\|\s*([0-9,]+)\s*\|} $text -> bram
    regexp {\|\s*DSPs\s*\|\s*([0-9,]+)\s*\|} $text -> dsp
    return [list [string map {, {}} $lut] [string map {, {}} $ff] [string map {, {}} $bram] [string map {, {}} $dsp]]
}

proc numeric_ge_zero {value} {
    if {$value eq "NA" || $value eq "UNSUPPORTED"} { return 0 }
    return [expr {double($value) >= 0.0}]
}

proc close_if_open {} {
    if {[llength [get_designs -quiet]] > 0} {
        catch {close_design}
    }
}

proc verify_loaded_checkpoint {expected_top expected_part expected_clock expected_period} {
    set d [current_design]
    set design_name [prop_or_na $d NAME]
    set design_top [prop_or_na $d TOP]
    set design_part [prop_or_na $d PART]
    if {$design_name ne $expected_top && $design_top ne $expected_top} {
        error "checkpoint top mismatch: NAME=$design_name TOP=$design_top expected=$expected_top"
    }
    if {![string match -nocase *xc7z020clg400-1* $design_part] && ![string match -nocase *7z020-clg400* $design_part]} {
        error "checkpoint part mismatch: PART=$design_part expected=$expected_part"
    }
    set clock_obj [get_clocks -quiet $expected_clock]
    if {[llength $clock_obj] != 1} {
        error "expected exactly one $expected_clock clock, got [llength $clock_obj]"
    }
    set actual_period [prop_or_na $clock_obj PERIOD]
    if {$actual_period eq "NA" || [expr {abs(double($actual_period) - double($expected_period)) > 0.0001}]} {
        error "checkpoint clock mismatch: $expected_clock period=$actual_period expected=$expected_period"
    }
    return [list $design_name $design_top $design_part $actual_period]
}

# Audit the immutable input DCP and the directive record from the historical
# banked run.  A post-synthesis DCP does not contain a project implementation
# run object, so the original directives are taken from its adjacent settings
# file and the loaded checkpoint properties are checked independently.
close_if_open
open_checkpoint $baseline_dcp
set baseline_props [verify_loaded_checkpoint $top $part $clock_name $clock_period_ns]
set baseline_design [current_design]
set baseline_clocks [get_clocks -quiet]
set baseline_settings_text [read_text $baseline_settings]
foreach required_setting {
    "place_directive=Explore"
    "phys_opt_directive=Explore"
    "route_directive=Explore"
    "synth_directive=RuntimeOptimized"
} {
    if {[string first $required_setting $baseline_settings_text] < 0} {
        error "historical banked directive record missing: $required_setting"
    }
}

set audit [open [file join $out baseline_dcp_audit.txt] w]
puts $audit "baseline_dcp=$baseline_dcp"
puts $audit "baseline_dcp_size_bytes=[file size $baseline_dcp]"
puts $audit "design_name=[lindex $baseline_props 0]"
puts $audit "design_top_property=[lindex $baseline_props 1]"
puts $audit "design_part=[lindex $baseline_props 2]"
puts $audit "clock_count=[llength $baseline_clocks]"
foreach c $baseline_clocks {
    puts $audit "clock=[prop_or_na $c NAME] period_ns=[prop_or_na $c PERIOD] waveform=[prop_or_na $c WAVEFORM]"
}
puts $audit "historical_settings=$baseline_settings"
puts $audit "historical_synth_directive=RuntimeOptimized"
puts $audit "historical_place_directive=Explore"
puts $audit "historical_phys_opt_directive=Explore"
puts $audit "historical_route_directive=Explore"
puts $audit "input_kind=immutable post-synthesis DCP; no RTL/TB/source read"
puts $audit "input_exclusion=onehot DCP rejected by path guard"
puts $audit "clock_policy=preserve checkpoint clock; no clock uncertainty/false-path/multicycle edits"
close $audit

# The help snapshots are evidence that the exact physical directives were
# accepted by this Vivado build; failures are recorded but do not alter the
# recipes or the checkpoint.
foreach pair {
    {place_design place_design_help.txt}
    {phys_opt_design phys_opt_design_help.txt}
    {route_design route_design_help.txt}
} {
    set command_name [lindex $pair 0]
    set help_path [file join $out [lindex $pair 1]]
    if {[catch {redirect -file $help_path [list help $command_name]} help_error]} {
        write_text $help_path "help_error=$help_error\n"
    }
}
close_if_open

set recipes [list \
    [dict create name recipe_01_phys_aggressive place Explore phys AggressiveExplore route AggressiveExplore description {Explore placement plus AggressiveExplore physical optimization and routing}] \
    [dict create name recipe_02_extra_net_delay place ExtraNetDelay_high phys AggressiveExplore route AggressiveExplore description {ExtraNetDelay_high placement plus AggressiveExplore physical optimization and routing}] \
    [dict create name recipe_03_spread_fanout_delay place AltSpreadLogic_high phys AggressiveFanoutOpt route HigherDelayCost description {AltSpreadLogic_high placement plus AggressiveFanoutOpt and HigherDelayCost routing}]
]

set summary_path [file join $out phys_recipe_summary.tsv]
set summary [open $summary_path w]
puts $summary "recipe\tplace_directive\tphys_opt_directive\troute_directive\tplace_status\tphys_opt_status\troute_status\troute_complete\tWNS_ns\tTNS_ns\tWHS_ns\tTHS_ns\tLUTs\tFFs\tBRAM_tiles\tDSPs\troutable_nets\tfully_routed_nets\trouting_errors\tpost_route_dcp"

set closure_found 0
set completed 0
set recipe_index 0
foreach recipe $recipes {
    if {$closure_found} { break }
    incr recipe_index
    set recipe_name [dict get $recipe name]
    set place_directive [dict get $recipe place]
    set phys_directive [dict get $recipe phys]
    set route_directive [dict get $recipe route]
    set recipe_description [dict get $recipe description]
    set recipe_out [file normalize [file join $out $recipe_name]]
    file mkdir $recipe_out

    set settings [open [file join $recipe_out run_settings.txt] w]
    puts $settings "tool=Vivado 2025.2"
    puts $settings "part=$part"
    puts $settings "top=$top"
    puts $settings "clock=$clock_name"
    puts $settings "clock_period_ns=$clock_period_ns"
    puts $settings "flow=read same immutable post-synthesis DCP; place/phys_opt/route"
    puts $settings "synth_mode=not rerun"
    puts $settings "place_directive=$place_directive"
    puts $settings "phys_opt_directive=$phys_directive"
    puts $settings "route_directive=$route_directive"
    puts $settings "general.maxThreads=$actual_threads"
    puts $settings "baseline_dcp=$baseline_dcp"
    puts $settings "baseline_dcp_guard=reject path containing onehot"
    puts $settings "description=$recipe_description"
    puts $settings "constraint_policy=preserve DCP clock; no false/multicycle/uncertainty relaxation; no LOC/RLOC"
    puts $settings "boundary=isolated ds12_stream_ds2_pw_consumer OOC; not full top/network"
    close $settings
    write_text [file join $recipe_out source_manifest_used.txt] "input_dcp=$baseline_dcp\ninput_kind=post-synthesis checkpoint\nrtl_tb_read=0\n"

    close_if_open
    open_checkpoint $baseline_dcp
    verify_loaded_checkpoint $top $part $clock_name $clock_period_ns

    set place_status ERROR
    set phys_status ERROR
    set route_status ERROR
    set route_complete 0
    if {[catch {place_design -directive $place_directive} message]} {
        write_text [file join $recipe_out place_error.txt] "$message\n"
    } else {
        set place_status PASS
    }
    if {$place_status eq "PASS"} {
        if {[catch {phys_opt_design -directive $phys_directive} message]} {
            write_text [file join $recipe_out phys_opt_error.txt] "$message\n"
        } else {
            set phys_status PASS
        }
    }
    if {$place_status eq "PASS" && $phys_status eq "PASS"} {
        if {[catch {route_design -directive $route_directive} message]} {
            write_text [file join $recipe_out route_error.txt] "$message\n"
        } else {
            set route_status PASS
        }
    }

    set timing_report [file join $recipe_out timing_summary_post_route.txt]
    set util_report [file join $recipe_out utilization_post_route.txt]
    set route_report [file join $recipe_out route_status_post_route.txt]
    set dcp_path [file join $recipe_out ds12_stream_ds2_pw_consumer_ooc_8ns_post_route.dcp]
    if {$route_status eq "PASS"} {
        report_timing_summary -delay_type min_max -max_paths 100 -report_unconstrained -file $timing_report
        report_timing -delay_type max -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $recipe_out reg_to_reg_maxpaths.txt]
        report_timing -delay_type min -from [all_registers] -to [all_registers] -max_paths 200 -file [file join $recipe_out reg_to_reg_minpaths.txt]
        report_utilization -file $util_report
        report_route_status -file $route_report
        report_design_analysis -congestion -file [file join $recipe_out congestion_post_route.txt]
        report_high_fanout_nets -max_nets 100 -file [file join $recipe_out high_fanout_post_route.txt]
        report_drc -file [file join $recipe_out drc_post_route.txt]
        set route_data [parse_route_status $route_report]
        set route_complete [lindex $route_data 0]
        if {$route_complete} {
            write_checkpoint -force $dcp_path
        }
    } else {
        write_text $timing_report "timing_summary=unavailable\n"
        write_text $util_report "utilization=unavailable\n"
        write_text $route_report "route_status=$route_status\n"
        set route_data [list 0 NA NA NA]
    }

    set wns NA
    set tns NA
    set whs NA
    set ths NA
    if {$route_complete && [file exists $timing_report]} {
        set timing_data [parse_timing_summary $timing_report]
        set wns [lindex $timing_data 0]
        set tns [lindex $timing_data 1]
        set whs [lindex $timing_data 2]
        set ths [lindex $timing_data 3]
    }
    set resources [parse_utilization $util_report]
    set lut [lindex $resources 0]
    set ff [lindex $resources 1]
    set bram [lindex $resources 2]
    set dsp [lindex $resources 3]
    set routable [lindex $route_data 1]
    set fully [lindex $route_data 2]
    set errors [lindex $route_data 3]
    set dcp_ok [file exists $dcp_path]
    set accepted [expr {$route_complete && $dcp_ok && [numeric_ge_zero $wns] && [numeric_ge_zero $whs] && [string is double -strict $tns] && double($tns) == 0.0}]
    if {$route_complete && $dcp_ok} { incr completed }

    puts $summary "$recipe_name\t$place_directive\t$phys_directive\t$route_directive\t$place_status\t$phys_status\t$route_status\t$route_complete\t$wns\t$tns\t$whs\t$ths\t$lut\t$ff\t$bram\t$dsp\t$routable\t$fully\t$errors\t$dcp_path"
    flush $summary

    set result [open [file join $recipe_out result.txt] w]
    puts $result "recipe=$recipe_name"
    puts $result "description=$recipe_description"
    puts $result "baseline_dcp=$baseline_dcp"
    puts $result "place_directive=$place_directive"
    puts $result "phys_opt_directive=$phys_directive"
    puts $result "route_directive=$route_directive"
    puts $result "place_status=$place_status"
    puts $result "phys_opt_status=$phys_status"
    puts $result "route_status=$route_status"
    puts $result "route_complete=$route_complete"
    puts $result "WNS_ns=$wns"
    puts $result "TNS_ns=$tns"
    puts $result "WHS_ns=$whs"
    puts $result "THS_ns=$ths"
    puts $result "LUTs=$lut"
    puts $result "FFs=$ff"
    puts $result "BRAM_tiles=$bram"
    puts $result "DSPs=$dsp"
    puts $result "routable_nets=$routable"
    puts $result "fully_routed_nets=$fully"
    puts $result "routing_errors=$errors"
    puts $result "post_route_dcp=$dcp_path"
    puts $result "accepted_setup_tns_hold=$accepted"
    close $result

    if {$accepted} {
        set closure_found 1
        set best [open [file join $out accepted_recipe.txt] w]
        puts $best "recipe=$recipe_name"
        puts $best "source_dir=$recipe_out"
        puts $best "WNS_ns=$wns"
        puts $best "TNS_ns=$tns"
        puts $best "WHS_ns=$whs"
        close $best
    }
}
close $summary

set overall [open [file join $out sweep_result.txt] w]
puts $overall "recipes_requested=[llength $recipes]"
puts $overall "recipes_completed_route=$completed"
puts $overall "closure_found=$closure_found"
puts $overall "baseline_dcp=$baseline_dcp"
puts $overall "baseline_dcp_kind=historical banked post-synthesis DCP"
puts $overall "boundary=isolated DS2 PW consumer OOC only; not full-top/network/power/energy/hardware"
close $overall

close_if_open
puts "DS2_PW_PHYS_DCP_DONE closure_found=$closure_found recipes_completed_route=$completed out=$out"
exit
