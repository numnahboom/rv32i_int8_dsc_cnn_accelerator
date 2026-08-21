# Portable out-of-context implementation flow for cnn_top.
#
# Usage:
#   vivado -mode batch -source scripts/vivado_cnn_top_impl.tcl \
#     -tclargs cnn_top <timing-capable-part>
#
# The flow intentionally has no board pin constraints.  It creates a 100 MHz
# core-clock implementation result and records all outcomes under build/reports.

set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ".."]]

if {[llength $argv] >= 2} {
    set top_name [lindex $argv 0]
    set part_name [lindex $argv 1]
} elseif {[llength $argv] == 1 && [string length [lindex $argv 0]] > 0} {
    set top_name "cnn_top"
    set part_name [lindex $argv 0]
} elseif {[info exists ::env(VIVADO_PART)] && [string length $::env(VIVADO_PART)] > 0} {
    set top_name "cnn_top"
    set part_name $::env(VIVADO_PART)
} else {
    # Kept consistent with the synthesis script.  Some installations contain
    # only a non-timing K26 support database; that condition is reported as a
    # deliberate failure below rather than being presented as timing closure.
    set top_name "cnn_top"
    set part_name "xck26-sfvc784-2LV-c"
}

if {[info exists ::env(VIVADO_IMPL_OUT_DIR)] && [string length $::env(VIVADO_IMPL_OUT_DIR)] > 0} {
    set out_dir [file normalize $::env(VIVADO_IMPL_OUT_DIR)]
} else {
    set out_dir [file join $project_root "build" "reports" "vivado_${top_name}_impl"]
}
file mkdir $out_dir
set manifest_file [file join $out_dir "manifest.txt"]
set constraint_file [file join $project_root "constraints" "cnn_top_ooc.xdc"]
set_param general.maxThreads 4

if {[info exists ::env(VIVADO_IMPL_RUN_ID)] && [string length $::env(VIVADO_IMPL_RUN_ID)] > 0} {
    set run_id $::env(VIVADO_IMPL_RUN_ID)
} else {
    set run_id "direct-[clock seconds]-[pid]"
}

array set stage_status {}

proc git_metadata {project_root} {
    set head "unavailable"
    if {![catch {exec git -c safe.directory=$project_root -C $project_root rev-parse HEAD} value]} {
        set head [string trim $value]
    }

    set status "unavailable"
    if {![catch {exec git -c safe.directory=$project_root -C $project_root status --porcelain=v1 --untracked-files=all} value]} {
        set status [string trim $value]
    }
    set dirty "unknown"
    if {$status ne "unavailable"} {
        set dirty [expr {[string length $status] > 0 ? "true" : "false"}]
    }

    # Hash the exact tracked diff against HEAD.  Recreate it with the command
    # recorded below; untracked names are separately recorded in git_status.
    set diff_hash "unavailable"
    set diff_hash_error ""
    set tmp_file ""
    set err_file ""
    if {[catch {
        set tmp_file [file join [pwd] ".cnn_impl_diff_[pid]_[clock clicks].patch"]
        set err_file [file join [pwd] ".cnn_impl_diff_[pid]_[clock clicks].err"]
        # Redirect directly to a file so the Git object hash is of the exact
        # byte stream produced by the documented reproduction command.
        exec git -c safe.directory=$project_root -c core.safecrlf=false -C $project_root diff --binary HEAD > $tmp_file 2> $err_file
        set value [exec git hash-object $tmp_file]
        file delete -force $tmp_file
        file delete -force $err_file
    } diff_hash_error]} {
        if {$tmp_file ne ""} { catch {file delete -force $tmp_file} }
        if {$err_file ne ""} { catch {file delete -force $err_file} }
    } else {
        set diff_hash [string trim $value]
    }

    set untracked_hash "unavailable"
    set untracked_hash_error ""
    set untracked_count "unavailable"
    set tmp_file ""
    if {[catch {
        set untracked_paths [split [string trim [exec git -c safe.directory=$project_root -C $project_root ls-files --others --exclude-standard]] "\n"]
        if {[llength $untracked_paths] == 1 && [lindex $untracked_paths 0] eq ""} {
            set untracked_paths {}
        }
        set untracked_count [llength $untracked_paths]
        set tmp_file [file join [pwd] ".cnn_impl_untracked_[pid]_[clock clicks].bundle"]
        set tmp_fh [open $tmp_file "w"]
        fconfigure $tmp_fh -translation binary -encoding binary
        foreach rel_path [lsort $untracked_paths] {
            set source_path [file join $project_root $rel_path]
            puts -nonewline $tmp_fh "path:$rel_path\n"
            set source_fh [open $source_path "r"]
            fconfigure $source_fh -translation binary -encoding binary
            fcopy $source_fh $tmp_fh
            close $source_fh
            puts -nonewline $tmp_fh "\nend:$rel_path\n"
        }
        close $tmp_fh
        set value [exec git hash-object $tmp_file]
        file delete -force $tmp_file
    } untracked_hash_error]} {
        if {$tmp_file ne ""} { catch {file delete -force $tmp_file} }
    } else {
        set untracked_hash [string trim $value]
    }
    return [dict create head $head dirty $dirty diff_hash $diff_hash diff_hash_error $diff_hash_error untracked_hash $untracked_hash untracked_hash_error $untracked_hash_error untracked_count $untracked_count git_status $status]
}

proc write_manifest {path project_root top_name part_name command_line final_status final_detail stage_pairs} {
    global run_id source_metadata
    set fh [open $path "w"]
    puts $fh "format: cnn-vivado-implementation-manifest-v2"
    puts $fh "run_id: $run_id"
    puts $fh "timestamp: [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S%z}]"
    puts $fh "git_head: [dict get $source_metadata head]"
    puts $fh "git_dirty: [dict get $source_metadata dirty]"
    puts $fh "git_diff_hash: [dict get $source_metadata diff_hash]"
    puts $fh "git_diff_hash_scope: tracked diff against HEAD; untracked paths are listed in git_status"
    puts $fh "git_diff_hash_command: git -C <project_root> -c core.safecrlf=false diff --binary HEAD | git hash-object --stdin"
    puts $fh "git_diff_hash_error: [string map [list "\n" " | " "\r" ""] [dict get $source_metadata diff_hash_error]]"
    puts $fh "git_untracked_content_hash: [dict get $source_metadata untracked_hash]"
    puts $fh "git_untracked_count: [dict get $source_metadata untracked_count]"
    puts $fh "git_untracked_hash_scope: sorted untracked path/content bundle; paths are listed in git_status"
    puts $fh "git_untracked_hash_error: [string map [list "\n" " | " "\r" ""] [dict get $source_metadata untracked_hash_error]]"
    puts $fh "git_status: [string map [list "\n" " | " "\r" ""] [dict get $source_metadata git_status]]"
    puts $fh "vivado_version: [version -short]"
    puts $fh "top: $top_name"
    puts $fh "part: $part_name"
    puts $fh "closure_scope: post-route out-of-context core-clock check only; board IO/clock constraints are excluded"
    puts $fh "command: $command_line"
    puts $fh "status: $final_status"
    puts $fh "detail: [string map [list "\n" " | " "\r" ""] $final_detail]"
    foreach {stage stage_value} $stage_pairs {
        puts $fh "stage.$stage: [string map [list "\n" " | " "\r" ""] $stage_value]"
    }
    close $fh
}

proc run_stage {stage_name command} {
    upvar 1 stage_status stage_status
    set rc [catch {uplevel 1 $command} message]
    if {$rc == 0} {
        set stage_status($stage_name) "PASSED"
    } else {
        set stage_status($stage_name) "FAILED: $message"
    }
    return $rc
}

proc fail_flow {manifest_file project_root top_name part_name command_line status detail stage_pairs} {
    write_manifest $manifest_file $project_root $top_name $part_name $command_line $status $detail $stage_pairs
    error "$status: $detail"
}

proc classify_implementation_failure {detail} {
    if {[string match -nocase "*non-timing*" $detail] || [string match -nocase "*timing device*" $detail]} {
        return "FAILED_NON_TIMING_PART"
    }
    return "FAILED_IMPLEMENTATION"
}

proc get_design_status {property_name} {
    if {[catch {set value [get_property $property_name [current_design]]}]} {
        return "UNAVAILABLE"
    }
    return $value
}

proc parse_timing_summary {timing_file first_header second_header first_key second_key} {
    set fh [open $timing_file "r"]
    set text [read $fh]
    close $fh
    set saw_header 0
    set first_index -1
    set second_index -1
    foreach line [split $text "\n"] {
        if {[string first $first_header $line] >= 0 && [string first $second_header $line] >= 0} {
            set saw_header 1
            if {[string first "|" $line] >= 0} {
                set header_columns {}
                foreach column [split $line "|"] {
                    lappend header_columns [string trim $column]
                }
            } else {
                set header_columns [regexp -all -inline {\S+} $line]
            }
            set first_index [lsearch -exact $header_columns $first_header]
            set second_index [lsearch -exact $header_columns $second_header]
            continue
        }
        if {$saw_header && $first_index >= 0 && $second_index >= 0} {
            if {[string first "|" $line] >= 0} {
                set value_columns {}
                foreach column [split $line "|"] {
                    lappend value_columns [string trim $column]
                }
            } else {
                set value_columns [regexp -all -inline {\S+} $line]
            }
            if {[llength $value_columns] > $first_index && [llength $value_columns] > $second_index} {
                set first_value [lindex $value_columns $first_index]
                set second_value [lindex $value_columns $second_index]
                if {[string is double -strict $first_value] && [string is double -strict $second_value]} {
                    return [dict create $first_key $first_value $second_key $second_value]
                }
            }
        }
    }
    return [dict create $first_key "UNPARSEABLE" $second_key "UNPARSEABLE"]
}

proc no_unconstrained_paths {unconstrained_file} {
    set fh [open $unconstrained_file "r"]
    set text [read $fh]
    close $fh
    # Vivado uses one of these phrases when report_timing -unconstrained found
    # no paths.  An unknown report format is deliberately not closure-safe.
    if {[regexp -nocase {no (unconstrained |timing )?paths found} $text] ||
        [regexp -nocase {no unconstrained paths} $text]} {
        return 1
    }
    return 0
}

set invocation "[info nameofexecutable] -mode batch -source scripts/vivado_cnn_top_impl.tcl -tclargs $top_name $part_name"
set source_metadata [git_metadata $project_root]
set stage_status(manifest_initialized) "PASSED"
write_manifest $manifest_file $project_root $top_name $part_name $invocation "RUNNING" "Vivado flow started; this manifest belongs only to run $run_id." [array get stage_status]

# Keep this list deliberately identical to scripts/vivado_cnn_top_synth.tcl.
set rtl_files [list \
    "rtl/common/round_shift.v" \
    "rtl/common/saturate_int8.v" \
    "rtl/cnn/requant_activation_unit.v" \
    "rtl/cnn/requant_activation_pipeline.v" \
    "rtl/cnn/systolic_pe.v" \
    "rtl/cnn/pw_systolic_array_8x8.v" \
    "rtl/cnn/dw_line_buffer.v" \
    "rtl/cnn/dw_mac_lanes.v" \
    "rtl/cnn/dw_tile_buffer_bram.v" \
    "rtl/cnn/ds_input_tile_buffer_bram.v" \
    "rtl/cnn/pw_weight_buffer_bram.v" \
    "rtl/cnn/dw_tile_fusion_engine_new.v" \
    "rtl/cnn/ds_block_tile_engine_new.v" \
    "rtl/cnn/conv3x3_stem_engine_new.v" \
    "rtl/cnn/gap_unit_new.v" \
    "rtl/cnn/fc_unit_new.v" \
    "rtl/cnn/tile_scheduler.v" \
    "rtl/cnn/feature_sram_bank.v" \
    "rtl/cnn/feature_sram_pingpong.v" \
    "rtl/cnn/status_counter.v" \
    "rtl/cnn/descriptor_fetch.v" \
    "rtl/cnn/cnn_layer_runner.v" \
    "rtl/cnn/cnn_top_ctrl.v" \
    "rtl/cnn/cnn_top.v" \
]

foreach f $rtl_files {
    set read_stage "read_[file rootname [file tail $f]]"
    if {[run_stage $read_stage [list read_verilog -sv [file join $project_root $f]]]} {
        fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_READ_RTL" [set stage_status($read_stage)] [array get stage_status]
    }
}

# The clock must exist before synthesis so the optimizer receives the intended
# timing objective.  The XDC has no package/pin assumptions and is portable.
if {![file exists $constraint_file]} {
    set stage_status(read_xdc) "FAILED: missing $constraint_file"
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_CONSTRAINT" $stage_status(read_xdc) [array get stage_status]
}
if {[run_stage read_xdc [list read_xdc $constraint_file]]} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_CONSTRAINT" $stage_status(read_xdc) [array get stage_status]
}

if {[run_stage synth_design [list synth_design -top $top_name -part $part_name -flatten_hierarchy none -mode out_of_context -directive RuntimeOptimized]]} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_SYNTHESIS" $stage_status(synth_design) [array get stage_status]
}

# Preserve useful synthesis evidence even when implementation cannot run on a
# device support package without timing data.
run_stage report_clocks_synth [list report_clocks -file [file join $out_dir "clocks_synth.txt"]]
run_stage report_utilization_synth [list report_utilization -file [file join $out_dir "utilization_synth.txt"]]
run_stage write_checkpoint_synth [list write_checkpoint -force [file join $out_dir "${top_name}_synth.dcp"]]

# read_xdc is intentionally before synth_design.  On a timing-capable device,
# confirm after elaboration that it resolved to exactly one named core clock
# rather than silently skipping a not-yet-visible top-level port.  K26's local
# database rejects every timing API, including get_clocks/report_clocks; that
# case is explicitly a non-timing-part failure, not a constraint failure.
set clk_objects [get_clocks -quiet clk]
set clk_count [llength $clk_objects]
set stage_status(clock_count) $clk_count
if {$clk_count != 1} {
    if {[info exists stage_status(report_clocks_synth)] && [classify_implementation_failure $stage_status(report_clocks_synth)] eq "FAILED_NON_TIMING_PART"} {
        set stage_status(clock_count) "UNAVAILABLE_NON_TIMING_PART"
        set stage_status(timing_device) "FAILED: timing APIs unavailable on this part"
        fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_NON_TIMING_PART" "XDC was read before synthesis, but this part rejects report_clocks/get_clocks because it has no timing database; synthesis reports were retained." [array get stage_status]
    }
    # Vivado 2021.2 can consume the pre-synthesis XDC yet not expose a
    # queryable clock object until the top is synthesized.  Repair only this
    # timing-capable case, then validate it; do not silently continue.
    set clk_ports [get_ports -quiet clk]
    if {[llength $clk_ports] != 1} {
        fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_CONSTRAINT" "Expected exactly one top-level clk port after synthesis, found [llength $clk_ports]." [array get stage_status]
    }
    if {[run_stage create_clock_post_synth [list create_clock -name clk -period 10.000 $clk_ports]]} {
        fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_CONSTRAINT" $stage_status(create_clock_post_synth) [array get stage_status]
    }
    set clk_objects [get_clocks -quiet clk]
    set clk_count [llength $clk_objects]
    set stage_status(clock_count) $clk_count
    if {$clk_count != 1} {
        fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_CONSTRAINT" "Expected exactly one clock named clk after post-synthesis creation, found $clk_count." [array get stage_status]
    }
}
set clk_period [get_property PERIOD [lindex $clk_objects 0]]
set stage_status(clock_period_ns) $clk_period
if {![string is double -strict $clk_period] || abs($clk_period - 10.0) > 0.0001} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_CONSTRAINT" "Clock clk period is '$clk_period' ns; expected 10.000 ns." [array get stage_status]
}

set timing_property ""
set timing_property_known 0
foreach property_name {IS_TIMING_DEVICE IS_TIMING_PART} {
    if {![catch {set timing_property [get_property $property_name [current_part]]}]} {
        if {$timing_property ne ""} {
            set timing_property_known 1
            break
        }
    }
}
if {$timing_property_known && ![string is true -strict $timing_property]} {
    set stage_status(timing_device) "FAILED: part has no timing database"
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_NON_TIMING_PART" "Part $part_name has no timing database; synthesis reports were retained, implementation was not attempted." [array get stage_status]
}
set stage_status(timing_device) "UNREPORTED: implementation commands will prove timing capability"

if {[run_stage opt_design [list opt_design -directive Explore]]} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation [classify_implementation_failure $stage_status(opt_design)] $stage_status(opt_design) [array get stage_status]
}
if {[run_stage place_design [list place_design -directive Explore]]} {
    set failure_status [classify_implementation_failure $stage_status(place_design)]
    fail_flow $manifest_file $project_root $top_name $part_name $invocation $failure_status $stage_status(place_design) [array get stage_status]
}
set place_status [get_design_status PLACE_STATUS]
set stage_status(place_status) $place_status
if {$place_status eq "UNAVAILABLE" || [lsearch -exact {PLACED PLACED_AND_FIXED} $place_status] < 0} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_IMPLEMENTATION_STATUS" "place_design returned successfully but PLACE_STATUS is '$place_status', not PLACED." [array get stage_status]
}
if {[run_stage phys_opt_design [list phys_opt_design -directive Explore]]} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation [classify_implementation_failure $stage_status(phys_opt_design)] $stage_status(phys_opt_design) [array get stage_status]
}
if {[run_stage route_design [list route_design -directive Explore]]} {
    set failure_status [classify_implementation_failure $stage_status(route_design)]
    fail_flow $manifest_file $project_root $top_name $part_name $invocation $failure_status $stage_status(route_design) [array get stage_status]
}
set route_status [get_design_status ROUTE_STATUS]
set stage_status(route_status) $route_status
if {$route_status eq "UNAVAILABLE" || [lsearch -exact {ROUTED FULLY_ROUTED} $route_status] < 0} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_IMPLEMENTATION_STATUS" "route_design returned successfully but ROUTE_STATUS is '$route_status', not ROUTED." [array get stage_status]
}
set stage_status(timing_device) "PASSED_BY_IMPLEMENTATION"

# Completion is only declared after route, required signoff reports, and
# explicit timing/constraint closure checks.
set report_failures 0
foreach {stage command} [list \
    report_timing_summary [list report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained -check_timing_verbose -file [file join $out_dir "timing_summary.txt"]] \
    report_timing [list report_timing -delay_type max -max_paths 20 -file [file join $out_dir "timing_maxpaths.txt"]] \
    report_utilization [list report_utilization -file [file join $out_dir "utilization_post_route.txt"]] \
    report_route_status [list report_route_status -file [file join $out_dir "route_status.txt"]] \
    report_power [list report_power -file [file join $out_dir "power.txt"]] \
    write_checkpoint_impl [list write_checkpoint -force [file join $out_dir "${top_name}_impl.dcp"]] \
] {
    if {[run_stage $stage $command]} {
        set report_failures 1
    }
}

if {$report_failures} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_SIGNOFF_REPORT" "Route completed but at least one required post-route report/checkpoint failed; inspect manifest and retained reports." [array get stage_status]
}

set setup_negative_paths [get_timing_paths -quiet -setup -slack_lesser_than 0.0 -max_paths 1]
set hold_negative_paths [get_timing_paths -quiet -hold -slack_lesser_than 0.0 -max_paths 1]
set setup_worst_paths [get_timing_paths -quiet -setup -max_paths 1]
set hold_worst_paths [get_timing_paths -quiet -hold -max_paths 1]
set stage_status(setup_negative_path_count) [llength $setup_negative_paths]
set stage_status(hold_negative_path_count) [llength $hold_negative_paths]
if {[llength $setup_worst_paths] == 0 || [llength $hold_worst_paths] == 0} {
    set wns "UNAVAILABLE"
    set whs "UNAVAILABLE"
} else {
    set wns [get_property SLACK [lindex $setup_worst_paths 0]]
    set whs [get_property SLACK [lindex $hold_worst_paths 0]]
}
set tns [expr {[llength $setup_negative_paths] == 0 ? "0.000_DERIVED" : "NEGATIVE_PATH_PRESENT"}]
set ths [expr {[llength $hold_negative_paths] == 0 ? "0.000_DERIVED" : "NEGATIVE_PATH_PRESENT"}]
set stage_status(timing_wns_ns) $wns
set stage_status(timing_tns_ns) $tns
set stage_status(timing_whs_ns) $whs
set stage_status(timing_ths_ns) $ths
set unconstrained_ok [no_unconstrained_paths [file join $out_dir "timing_summary.txt"]]
set stage_status(unconstrained_paths) [expr {$unconstrained_ok ? "ZERO" : "NONZERO_OR_UNPARSEABLE"}]

set timing_closure_ok 1
if {![string is double -strict $wns] || ![string is double -strict $whs]} {
    set timing_closure_ok 0
    set stage_status(timing_parse) "FAILED: worst setup/hold slack could not be obtained from timing paths"
} elseif {$wns < 0.0 || $whs < 0.0} {
    set timing_closure_ok 0
    set stage_status(timing_slack) "FAILED: WNS=$wns ns, WHS=$whs ns"
} else {
    set stage_status(timing_slack) "PASSED: WNS=$wns ns, WHS=$whs ns; TNS/THS are zero by zero-negative-path proof"
}
if {!$unconstrained_ok} {
    set timing_closure_ok 0
}
if {[llength $setup_negative_paths] != 0 || [llength $hold_negative_paths] != 0} {
    set timing_closure_ok 0
    set stage_status(timing_path_query) "FAILED: negative setup or hold path exists"
} else {
    set stage_status(timing_path_query) "PASSED: no negative setup/hold path returned"
}

if {!$timing_closure_ok} {
    fail_flow $manifest_file $project_root $top_name $part_name $invocation "FAILED_TIMING_CLOSURE" "Implementation routed, but route/timing closure criteria failed; inspect timing_summary.txt (setup/hold and unconstrained-path report) and manifest." [array get stage_status]
}

write_manifest $manifest_file $project_root $top_name $part_name $invocation "PASSED_TIMING_CLOSURE" "Implementation routed with PLACED/ROUTED status, non-negative setup/hold WNS/TNS/WHS/THS, and zero unconstrained paths." [array get stage_status]
puts "Timing closure passed. Manifest: $manifest_file"
