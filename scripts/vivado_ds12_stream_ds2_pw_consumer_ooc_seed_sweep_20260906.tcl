# DS12 DS2 PW consumer: bounded 8 ns OOC physical sweep.
#
# This script deliberately starts every attempt from the same post-synthesis
# DCP and uses the retained Explore directives.  Vivado 2025.2's documented
# place_design/route_design interfaces and run properties do not expose the
# old ISE-style cost-table seed, so no unsupported seed property is invented.
# The requested labels (2,3,7,11) identify independent attempts; the report
# records that they are labels rather than tool-controlled random seeds.
# This is isolated module OOC evidence only: not full-top, power, energy,
# board, hardware, or full-network closure.

set root [file normalize [file join [file dirname [info script]] ..]]
set sweep_out [file normalize [file join $root build reports vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_seed_sweep_20260906]]
set baseline_out [file normalize [file join $root build reports vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906]]
set baseline_dcp [file normalize [file join $baseline_out ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_post_synth.dcp]]
set seed_manifest [file normalize [file join [file dirname [info script]] ds12_stream_ds2_pw_consumer_ooc_seed_sweep_20260906.txt]]
set source_manifest [file normalize [file join [file dirname [info script]] ds12_stream_ds2_pw_consumer_ooc_8ns_20260905.f]]

set part xc7z020clg400-1
set top ds12_stream_ds2_pw_consumer
set clock_period_ns 8.000
set requested_threads 8
set place_directive Explore
set phys_opt_directive Explore
set route_directive Explore

if {![file exists $baseline_dcp]} { error "missing immutable baseline post-synth DCP: $baseline_dcp" }
if {![file exists $seed_manifest]} { error "missing seed/attempt manifest: $seed_manifest" }
if {![file exists $source_manifest]} { error "missing source manifest: $source_manifest" }
file mkdir $sweep_out

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
    # Vivado 2025.2 emits a compact setup/hold summary near the end of the
    # report.  Keep the parser tolerant of wrapped whitespace and commas.
    if {[regexp -nocase {Setup\s*:\s*[0-9,]+\s+Failing Endpoints,\s+Worst Slack\s+(-?[0-9.]+)ns,\s+Total Violation\s+(-?[0-9.]+)ns} $text -> wns tns]} {
        # setup parsed
    }
    if {[regexp -nocase {Hold\s*:\s*[0-9,]+\s+Failing Endpoints,\s+Worst Slack\s+(-?[0-9.]+)ns,\s+Total Violation\s+(-?[0-9.]+)ns} $text -> whs ths]} {
        # hold parsed
    }
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
    if {$value eq "NA"} { return 0 }
    return [expr {double($value) >= 0.0}]
}

set attempts {}
set mf [open $seed_manifest r]
while {[gets $mf line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string match "#*" $line]} { continue }
    if {![string is integer -strict $line]} { error "invalid attempt label in $seed_manifest: $line" }
    lappend attempts $line
}
close $mf
if {[llength $attempts] > 4} { error "attempt manifest exceeds fixed budget: [llength $attempts]" }
if {[llength $attempts] == 0} { error "attempt manifest is empty" }

set summary_path [file join $sweep_out seed_sweep_summary.tsv]
set summary [open $summary_path w]
puts $summary "attempt_label\tseed_mode\tplace_status\tphys_opt_status\troute_status\troute_complete\tWNS_ns\tTNS_ns\tWHS_ns\tTHS_ns\tLUTs\tFFs\tBRAM_tiles\tDSPs\troutable_nets\tfully_routed_nets\trouting_errors\tpost_route_dcp\ttiming_report\tutilization_report"

set closure_found 0
set completed_count 0
set attempt_index 0
foreach label $attempts {
    if {$closure_found} { break }
    incr attempt_index
    set attempt [format "attempt_%02d_label_%s" $attempt_index $label]
    set out [file normalize [file join $sweep_out $attempt]]
    file mkdir $out
    set settings [open [file join $out run_settings.txt] w]
    puts $settings "tool=Vivado 2025.2"
    puts $settings "part=$part"
    puts $settings "top=$top"
    puts $settings "clock_period_ns=$clock_period_ns"
    puts $settings "flow=read immutable post-synthesis DCP; place/phys_opt/route"
    puts $settings "synth_mode=not rerun; source netlist loaded from DCP"
    puts $settings "place_directive=$place_directive"
    puts $settings "phys_opt_directive=$phys_opt_directive"
    puts $settings "route_directive=$route_directive"
    puts $settings "general.maxThreads=$actual_threads"
    puts $settings "attempt_label=$label"
    puts $settings "seed_mode=label_only; Vivado 2025.2 has no documented non-project place/route seed property"
    puts $settings "baseline_dcp=$baseline_dcp"
    puts $settings "source_manifest=$source_manifest"
    puts $settings "boundary=isolated ds12_stream_ds2_pw_consumer module; not full top/network"
    close $settings
    file copy -force $seed_manifest [file join $out seed_manifest_used.txt]
    file copy -force $source_manifest [file join $out source_manifest_used.txt]

    set seed_probe [open [file join $out seed_property_audit.txt] w]
    foreach property {place.seed route.seed} {
        set rc [catch {get_param $property} value]
        if {$rc == 0} {
            puts $seed_probe "GET $property=$value"
        } else {
            puts $seed_probe "GET $property=UNSUPPORTED"
        }
    }
    close $seed_probe

    if {[llength [get_designs -quiet]] > 0} { catch {close_design} }
    open_checkpoint $baseline_dcp
    set place_status ERROR
    set phys_opt_status ERROR
    set route_status ERROR
    set route_complete 0

    if {[catch {place_design -directive $place_directive} message]} {
        set place_status ERROR
        set f [open [file join $out place_error.txt] w]
        puts $f $message
        close $f
    } else {
        set place_status PASS
    }
    if {$place_status eq "PASS"} {
        if {[catch {phys_opt_design -directive $phys_opt_directive} message]} {
            set phys_opt_status ERROR
            set f [open [file join $out phys_opt_error.txt] w]
            puts $f $message
            close $f
        } else {
            set phys_opt_status PASS
        }
    }
    if {$place_status eq "PASS" && $phys_opt_status eq "PASS"} {
        if {[catch {route_design -directive $route_directive} message]} {
            set route_status ERROR
            set f [open [file join $out route_error.txt] w]
            puts $f $message
            close $f
        } else {
            set route_status PASS
        }
    }

    set timing_report [file join $out timing_summary_post_route.txt]
    set utilization_report [file join $out utilization_post_route.txt]
    set route_report [file join $out route_status_post_route.txt]
    if {$route_status eq "PASS"} {
        report_timing_summary -delay_type min_max -max_paths 100 -report_unconstrained -file $timing_report
        report_utilization -file $utilization_report
        report_route_status -file $route_report
        set route_data [parse_route_status $route_report]
        set route_complete [lindex $route_data 0]
        if {!$route_complete} {
            set route_status INCOMPLETE
        }
    } else {
        set f [open $route_report w]
        puts $f "route_status=$route_status"
        close $f
        set f [open $timing_report w]
        puts $f "timing_summary=unavailable"
        close $f
        set f [open $utilization_report w]
        puts $f "utilization=unavailable"
        close $f
        set route_data [list 0 NA NA NA]
    }

    set wns NA
    set tns NA
    set whs NA
    set ths NA
    if {$route_status eq "PASS" && [file exists $timing_report]} {
        set timing_data [parse_timing_summary $timing_report]
        set wns [lindex $timing_data 0]
        set tns [lindex $timing_data 1]
        set whs [lindex $timing_data 2]
        set ths [lindex $timing_data 3]
    }
    set resources [parse_utilization $utilization_report]
    set lut [lindex $resources 0]
    set ff [lindex $resources 1]
    set bram [lindex $resources 2]
    set dsp [lindex $resources 3]
    set routable [lindex $route_data 1]
    set fully [lindex $route_data 2]
    set errors [lindex $route_data 3]

    set dcp_path [file join $out ds12_stream_ds2_pw_consumer_ooc_8ns_post_route.dcp]
    if {$route_complete} {
        write_checkpoint -force $dcp_path
    }
    set dcp_ok [file exists $dcp_path]
    set timing_ok [numeric_ge_zero $wns]
    set hold_ok [numeric_ge_zero $whs]
    set accepted [expr {$route_complete && $dcp_ok && $timing_ok && $hold_ok}]
    if {$route_complete && $dcp_ok} { incr completed_count }

    puts $summary "$label\tlabel_only\t$place_status\t$phys_opt_status\t$route_status\t$route_complete\t$wns\t$tns\t$whs\t$ths\t$lut\t$ff\t$bram\t$dsp\t$routable\t$fully\t$errors\t$dcp_path\t$timing_report\t$utilization_report"
    flush $summary

    set result [open [file join $out result.txt] w]
    puts $result "attempt_label=$label"
    puts $result "seed_mode=label_only"
    puts $result "place_status=$place_status"
    puts $result "phys_opt_status=$phys_opt_status"
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
    puts $result "accepted_setup_hold=$accepted"
    close $result

    if {$accepted} {
        set closure_found 1
        # Preserve the first accepted attempt in a stable handoff location.
        # The sweep remains bounded and stops after this attempt; copying the
        # DCP plus its reports keeps the closure artifact independent of the
        # per-attempt directory naming.
        set best_dir [file join $sweep_out best]
        file mkdir $best_dir
        foreach artifact [list $dcp_path $timing_report $utilization_report $route_report [file join $out result.txt] [file join $out run_settings.txt] [file join $out seed_property_audit.txt]] {
            if {[file exists $artifact]} {
                file copy -force $artifact $best_dir
            }
        }
        set best_meta [open [file join $best_dir selected_attempt.txt] w]
        puts $best_meta "attempt_label=$label"
        puts $best_meta "source_attempt=$out"
        puts $best_meta "accepted_setup_hold=$accepted"
        close $best_meta
    }
}
close $summary

set overall [open [file join $sweep_out sweep_result.txt] w]
puts $overall "attempts_requested=[llength $attempts]"
puts $overall "attempts_completed_route=$completed_count"
puts $overall "closure_found=$closure_found"
puts $overall "seed_mode=label_only; explicit Vivado 2025.2 place/route seed unsupported"
puts $overall "boundary=isolated DS2 PW consumer OOC only; not full-top/network/power/energy/hardware"
close $overall
if {$closure_found} {
    puts "DS2_PW_SEED_SWEEP_PASS closure_found=1 out=$sweep_out"
} else {
    puts "DS2_PW_SEED_SWEEP_DONE closure_found=0 out=$sweep_out"
}
exit
