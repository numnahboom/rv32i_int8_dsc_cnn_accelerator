# Bounded A3 checkpoint ECO: bind actual body PG terminals, add only local
# non-inverting data delay on currently failing input branches and result DINs,
# then legalize, incrementally route, and report all required acceptance views.
proc a3_require_env {name} {
    if {![info exists ::env($name)] || $::env($name) eq ""} {
        error "Missing required environment variable $name"
    }
    return $::env($name)
}

proc a3_capture_report {out name command} {
    set report [file join $out $name]
    set status [file join $out report_command_status.tsv]
    set rc [catch {redirect $report $command} message]
    if {$rc && ![file exists $report]} {
        set f [open $report w]
        puts $f "REPORT_COMMAND_FAILED command=[join $command { }]"
        close $f
    }
    set clean_message [string map [list "\n" " " "\t" " "] $message]
    set f [open $status a]
    puts $f "$name\trc=$rc\tcommand=[join $command { }]\tmessage=$clean_message"
    close $f
    return $rc
}

proc a3_require_report {out name command} {
    set rc [a3_capture_report $out $name $command]
    if {$rc} {error "Required native report failed: $name"}
    return [file join $out $name]
}

proc a3_first_slack {report} {
    set f [open $report r]
    set text [read $f]
    close $f
    if {![regexp {Slack Time[ \t]+(-?[0-9]+(\.[0-9]+)?)} $text -> slack]} {
        error "No Slack Time was found in $report"
    }
    return [expr {double($slack)}]
}

proc a3_capture_help {out command} {
    set report [file join $out command_help_${command}.rpt]
    set f [open $report w]
    puts $f "COMMAND $command"
    close $f
    set rc [catch {redirect -append $report [list help $command]} message]
    set f [open $report a]
    puts $f "HELP_STATUS rc=$rc message=$message"
    close $f
}

proc a3_configure_workers {} {
    setMultiCpuUsage -localCpu 16
}

proc a3_configure_analysis {} {
    setDesignMode -process 180
    setAnalysisMode -analysisType onChipVariation -cppr both
    foreach corner {tt ss ff} {
        set_timing_derate -delay_corner DELAY_$corner -late 1.05
        set_timing_derate -delay_corner DELAY_$corner -early 0.95
    }
    set_analysis_view -setup {CORE_ss CORE_tt} -hold {CORE_ff}
}

proc a3_preflight {root out input} {
    if {![file isdirectory $input]} {error "Frozen A3 routed checkpoint is missing: $input"}
    a3_configure_workers
    restoreDesign $input d4_fullnet_top
    a3_configure_analysis
    source [file join $root scripts asic_pg_grid.tcl]
    lassign [d4_report_pg_inventory [file join $out pg_inventory_pre.tsv]] unassigned mismatched unknown
    a3_require_report $out check_timing.rpt [list check_timing -verbose]
    a3_require_report $out clocks.rpt [list report_clocks]
    foreach view {CORE_ss CORE_tt} {
        a3_require_report $out constraint_${view}.rpt \
            [list report_constraint -all_violators -late -view $view]
        a3_require_report $out setup_paths_${view}.rpt \
            [list report_timing -view $view -late -check_type setup -max_paths 100]
        a3_require_report $out unconstrained_${view}.rpt \
            [list report_timing -view $view -late -unconstrained -max_paths 10000 -path_exceptions all]
        a3_require_report $out path_exceptions_${view}.rpt \
            [list report_timing -view $view -late -path_exceptions all -max_paths 10000]
    }
    a3_require_report $out constraint_CORE_ff.rpt \
        [list report_constraint -all_violators -early -view CORE_ff]
    a3_require_report $out hold_paths_CORE_ff.rpt \
        [list report_timing -view CORE_ff -early -check_type hold -max_paths 1000 -max_slack 0.0 -path_exceptions all]
    a3_require_report $out unconstrained_CORE_ff.rpt \
        [list report_timing -view CORE_ff -early -unconstrained -max_paths 10000 -path_exceptions all]
    a3_require_report $out path_exceptions_CORE_ff.rpt \
        [list report_timing -view CORE_ff -early -path_exceptions all -max_paths 10000]
    foreach command {ecoAddRepeater ecoPlace ecoRoute timeDesign globalNetConnect sroute verifyConnectivity verify_drc report_timing report_constraint} {
        a3_capture_help $out $command
    }
    puts "D4_A3_PG_HOLD_PREFLIGHT_COMPLETE process_nm=180 setup_views=CORE_ss,CORE_tt hold_view=CORE_ff cppr=both pg_unassigned=$unassigned pg_mismatched=$mismatched pg_unknown=$unknown input_checkpoint=$input"
}

proc a3_collect_hold_targets {report target_report} {
    set f [open $report r]
    set text [read $f]
    close $f
    set images [dict create]
    set regs [dict create]
    set unhandled 0
    set paths 0
    set out [open $target_report w]
    puts $out "PATH\tSLACK_NS\tBEGINPOINT\tENDPOINT\tLOCAL_TERM\tACTION"
    set in_path 0
    set source ""
    set endpoint ""
    set term ""
    foreach line [split $text "\n"] {
        if {[regexp {^Path[ \t]+([0-9]+):} $line -> path_id]} {
            set in_path 1
            set source ""
            set endpoint ""
            set term ""
            continue
        }
        if {!$in_path} {continue}
        if {[regexp {^Endpoint:[ \t]+([^[:space:]]+)} $line -> value]} {
            set endpoint $value
            continue
        }
        if {[regexp {^Beginpoint:[ \t]+([^[:space:]]+)} $line -> value]} {
            set source $value
            continue
        }
        if {$source ne "" && $term eq "" &&
                [regexp {^[ \t]*\|[ \t]*([^|[:space:]]+/[^|[:space:]]+)[ \t]*\|} $line -> value]} {
            set term [string trim $value]
        }
        if {[regexp {^[ \t]*Slack Time[ \t]+(-?[0-9]+(\.[0-9]+)?)} $line -> slack]} {
            if {$slack < 0.0} {
                incr paths
                set action OTHER_UNHANDLED
                if {[regexp {^input_data\[([0-9]+)\]$} $source -> bit] && $term ne ""} {
                    set action IMAGE_BRANCH
                    if {[dict exists $images $bit]} {
                        set terms [dict get $images $bit]
                        if {[lsearch -exact $terms $term] < 0} {
                            dict set images $bit [linsert $terms end $term]
                        }
                    } else {
                        dict set images $bit [list $term]
                    }
                } elseif {[regexp {^result_vector_reg\[[0-9]+\]/Q$} $source] &&
                          [regexp {/macro/DIN\[[0-9]+\]$} $endpoint]} {
                    set action RESULT_VECTOR_SINK
                    dict set regs $endpoint 1
                } else {
                    incr unhandled
                }
                puts $out "$path_id\t$slack\t$source\t$endpoint\t$term\t$action"
            }
            set in_path 0
        }
    }
    close $out
    puts "D4_A3_HOLD_TARGET_SCAN paths=$paths image_bits=[dict size $images] result_sinks=[dict size $regs] unhandled=$unhandled report=$target_report"
    return [list $images $regs $paths $unhandled]
}

proc a3_add_local_repeaters {out stage image_targets result_targets} {
    set f [open [file join $out eco_insertion_plan.tsv] w]
    puts $f "TARGET_CLASS\tKEY\tTERM\tCELL\tBUFFER_INDEX\tNAME"
    set inserted 0
    if {$stage eq "eco1"} {set input_buffer_count 2} else {set input_buffer_count 1}
    set index 0
    foreach bit [lsort -integer [dict keys $image_targets]] {
        foreach term [dict get $image_targets $bit] {
            for {set n 1} {$n <= $input_buffer_count} {incr n} {
                if {$stage eq "eco1"} {
                    set name A3_HI_${bit}_${n}
                } else {
                    set name A3_HI2_${bit}_${n}
                }
                ecoAddRepeater -term [list $term] -cell {BUFHDV0} -name $name
                puts $f "IMAGE_BRANCH\t$bit\t$term\tBUFHDV0\t$n\t$name"
                incr inserted
            }
        }
    }
    foreach sink [lsort [dict keys $result_targets]] {
        incr index
        if {$stage eq "eco1"} {
            set name A3_HR_${index}
        } else {
            set name A3_HR2_${index}
        }
        ecoAddRepeater -term [list $sink] -cell {BUFHDV0} -name $name
        puts $f "RESULT_VECTOR_DIN\t$index\t$sink\tBUFHDV0\t1\t$name"
        incr inserted
    }
    close $f
    if {$inserted == 0} {error "No local hold-delay ECO targets were selected"}
    puts "D4_A3_LOCAL_REPEATER_INSERTION_COMPLETE stage=$stage count=$inserted cell=BUFHDV0"
}

proc a3_check_zero_connectivity {out name command} {
    set log [a3_capture_report $out ${name}_command.rpt $command]
    if {$log} {return 0}
    set report [file join $out ${name}.rpt]
    set f [open $report r]
    set text [read $f]
    close $f
    return [regexp {Verification Complete[ \t]*:[ \t]*0 Viols\.[ \t]*0 Wrngs\.} $text]
}

proc a3_check_zero_drc {out name command} {
    set rc [a3_capture_report $out ${name}_command.rpt $command]
    if {$rc} {return 0}
    set report [file join $out ${name}.rpt]
    if {![file exists $report]} {return 0}
    set f [open $report r]
    set text [read $f]
    close $f
    return [regexp {No DRC violations were found} $text]
}

proc a3_run_coverage {out} {
    a3_require_report $out check_timing.rpt [list check_timing -verbose]
    a3_require_report $out clocks.rpt [list report_clocks]
    set f [open [file join $out timing_summary.tsv] w]
    puts $f "CHECK\tVIEW\tWORST_SLACK_NS"
    set setup_ok 1
    foreach view {CORE_ss CORE_tt} {
        a3_require_report $out constraint_${view}.rpt \
            [list report_constraint -all_violators -late -view $view]
        a3_require_report $out setup_paths_${view}.rpt \
            [list report_timing -view $view -late -check_type setup -max_paths 200 -path_type full -path_exceptions all]
        a3_require_report $out unconstrained_${view}.rpt \
            [list report_timing -view $view -late -unconstrained -max_paths 10000 -path_exceptions all]
        a3_require_report $out path_exceptions_${view}.rpt \
            [list report_timing -view $view -late -path_exceptions all -max_paths 10000]
        set worst_file [a3_require_report $out setup_worst_${view}.rpt \
            [list report_timing -view $view -late -check_type setup -max_paths 1 -path_type full]]
        set slack [a3_first_slack $worst_file]
        puts $f "SETUP\t$view\t$slack"
        if {$slack < 0.0} {set setup_ok 0}
    }
    a3_require_report $out constraint_CORE_ff.rpt \
        [list report_constraint -all_violators -early -view CORE_ff]
    a3_require_report $out hold_paths_CORE_ff.rpt \
        [list report_timing -view CORE_ff -early -check_type hold -max_paths 10000 -max_slack 0.0 -path_type full -path_exceptions all]
    a3_require_report $out unconstrained_CORE_ff.rpt \
        [list report_timing -view CORE_ff -early -unconstrained -max_paths 10000 -path_exceptions all]
    a3_require_report $out path_exceptions_CORE_ff.rpt \
        [list report_timing -view CORE_ff -early -path_exceptions all -max_paths 10000]
    set worst_hold [a3_require_report $out hold_worst_CORE_ff.rpt \
        [list report_timing -view CORE_ff -early -check_type hold -max_paths 1 -path_type full]]
    set hold_slack [a3_first_slack $worst_hold]
    puts $f "HOLD\tCORE_ff\t$hold_slack"
    close $f
    return [list $setup_ok [expr {$hold_slack >= 0.0}] $hold_slack]
}

proc a3_run_eco {root out input stage} {
    if {![file isdirectory $input]} {error "A3 input checkpoint is missing: $input"}
    a3_configure_workers
    restoreDesign $input d4_fullnet_top
    a3_configure_analysis
    source [file join $root scripts asic_pg_grid.tcl]

    lassign [d4_report_pg_inventory [file join $out pg_inventory_before.tsv]] before_unassigned before_mismatched before_unknown
    d4_bind_pg_terminals [file join $out pg_inventory_bound_before_eco.tsv]

    set hold_before [a3_require_report $out hold_targets_before.rpt \
        [list report_timing -view CORE_ff -early -check_type hold -max_paths 10000 -max_slack 0.0 -path_type full -path_exceptions all]]
    lassign [a3_collect_hold_targets $hold_before [file join $out hold_target_inventory.tsv]] image_targets result_targets failing_paths unhandled
    if {$unhandled != 0} {
        error "Hold report contains $unhandled negative path(s) outside the assigned input_data/result_vector-to-memory-DIN branches"
    }
    if {$failing_paths == 0} {error "Expected baseline/candidate hold targets were not found"}
    a3_add_local_repeaters $out $stage $image_targets $result_targets
    ecoPlace -fixPlacedInsts true

    # Reapply logical PG mapping after ECO cells are present, then make physical
    # core-pin contact to the existing VDD/VSS stripe/followpin network.
    d4_bind_pg_terminals [file join $out pg_terminal_inventory_after_eco.tsv]
    set sroute_command [list sroute -nets {VDD VSS} -connect {corePin} -corePinTarget {stripe ring} \
        -layerChangeRange {METAL1 METAL6} -targetViaLayerRange {METAL6 METAL6} \
        -stripeLayerRange {METAL6 METAL6} -allowJogging 1 -allowLayerChange 1]
    if {[a3_capture_report $out pg_sroute_command.rpt $sroute_command]} {error "P/G core-pin incremental route failed"}
    if {[a3_capture_report $out eco_route_command.rpt [list ecoRoute]]} {error "Signal ECO route failed"}

    # Save the routed stage before checks so attempt 2 can resume the same
    # candidate if timing or physical verification needs the one allowed repair.
    saveDesign [file join $out routed_A3.enc]
    saveNetlist [file join $out routed_A3.v]
    rcOut -spef [file join $out routed_A3.spef]

    file mkdir [file join $out time_setup]
    file mkdir [file join $out time_hold]
    if {[a3_capture_report $out timeDesign_setup_command.rpt \
            [list timeDesign -postRoute -outDir [file join $out time_setup]]]} {
        error "Post-route setup extraction/report failed"
    }
    if {[a3_capture_report $out timeDesign_hold_command.rpt \
            [list timeDesign -postRoute -hold -outDir [file join $out time_hold]]]} {
        error "Post-route hold extraction/report failed"
    }

    # Full connectivity types plus a separate all-PG-pin physical contact
    # assertion. Logical global-net mapping alone never satisfies this gate.
    set connectivity_ok 1
    foreach type {all regular special} {
        if {![a3_check_zero_connectivity $out connectivity_${type} \
                [list verifyConnectivity -type $type -error 100000 -warning 100000 -report [file join $out connectivity_${type}.rpt]]]} {
            set connectivity_ok 0
        }
    }
    foreach net {VDD VSS} {
        if {![a3_check_zero_connectivity $out connectivity_${net} \
                [list verifyConnectivity -net $net -type all -error 100000 -warning 100000 -report [file join $out connectivity_${net}.rpt]]]} {
            set connectivity_ok 0
        }
    }
    if {![a3_check_zero_connectivity $out pg_pin_contact \
            [list verifyConnectivity -allPGPinPort -type all -error 100000 -warning 100000 -report [file join $out pg_pin_contact.rpt]]]} {
        set connectivity_ok 0
    }

    set drc_ok 1
    foreach scope {all cell regular special} {
        if {![a3_check_zero_drc $out drc_${scope} \
                [list verify_drc -check_only $scope -ignore_trial_route -limit 100000 -report [file join $out drc_${scope}.rpt]]]} {
            set drc_ok 0
        }
    }

    lassign [d4_report_pg_inventory [file join $out pg_terminal_inventory_final.tsv]] pg_unassigned pg_mismatched pg_unknown
    set pg_ok [expr {$pg_unassigned == 0 && $pg_mismatched == 0 && $pg_unknown == 0}]
    lassign [a3_run_coverage $out] setup_ok hold_ok hold_slack
    set ss_slack [a3_first_slack [file join $out setup_worst_CORE_ss.rpt]]
    set tt_slack [a3_first_slack [file join $out setup_worst_CORE_tt.rpt]]

    set status_file [open [file join $out status.txt] w]
    if {$pg_ok && $connectivity_ok && $drc_ok && $setup_ok && $hold_ok} {
        puts $status_file A3_ECO_ACCEPTED
        set status A3_ECO_ACCEPTED
    } else {
        puts $status_file ${stage}_REPAIR_NEEDED
        set status ${stage}_REPAIR_NEEDED
    }
    close $status_file
    puts "D4_A3_ECO_STAGE_COMPLETE stage=$stage status=$status setup_ss_ns=$ss_slack setup_tt_ns=$tt_slack hold_ff_ns=$hold_slack pg_unassigned=$pg_unassigned pg_mismatched=$pg_mismatched pg_unknown=$pg_unknown connectivity_ok=$connectivity_ok drc_ok=$drc_ok"
}

proc main {} {
    set root [a3_require_env D4_A3_ROOT]
    set out [a3_require_env D4_A3_STAGE_DIR]
    set input [a3_require_env D4_A3_INPUT_CHECKPOINT]
    set stage [a3_require_env D4_A3_STAGE]
    if {$stage eq "preflight"} {
        a3_preflight $root $out $input
    } elseif {$stage eq "eco1" || $stage eq "eco2"} {
        a3_run_eco $root $out $input $stage
    } else {
        error "Invalid A3 stage: $stage"
    }
}

if {[catch {main} message options]} {
    puts "D4_A3_PG_HOLD_ECO_FAIL=$message"
    if {[dict exists $options -errorinfo]} {puts [dict get $options -errorinfo]}
    exit 1
}
exit
