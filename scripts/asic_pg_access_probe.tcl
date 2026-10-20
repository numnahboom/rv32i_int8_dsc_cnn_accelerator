# One-macro P/G geometry experiment. Original routed evidence is untouched.
proc pg_probe {} {
    set root [file normalize [file join [file dirname [info script]] ..]]
    set out [pwd]
    setMultiCpuUsage -localCpu 4
    restoreDesign $root/build/reports/asic_A3_physical_20261020/routed.enc.dat d4_fullnet_top
    redirect $out/stripe_help.log {help setAddStripeMode;help addStripe}
    globalNetConnect VSS -type pgpin -pin GND -all -override
    globalNetConnect VSS -type pgpin -pin VSS -all
    globalNetConnect VDD -type pgpin -pin VDD -all
    set f [open $out/macro_pg_inventory.rpt w]
    set macro_count 0
    foreach inst [dbGet -p2 top.insts.cell.baseClass block] {
        incr macro_count
        puts $f "INSTANCE [dbGet $inst.name]"
        set pins [dbGet $inst.pgInstTerms]
        if {$pins eq "0x0" || [llength $pins]!=2} {error "Missing actual memory power/ground terminals"}
        foreach pin $pins {
            set name [dbGet $pin.name]
            set net [dbGet $pin.net.name]
            puts $f "PIN $name NET $net"
            if {$name eq "VDD"} {set expected VDD} elseif {$name eq "GND"} {set expected VSS} \
                else {error "Unexpected memory PG terminal"}
            if {$net ne $expected} {error "Incorrect memory PG terminal assignment"}
        }
    }
    close $f
    if {$macro_count!=19} {error "Expected 19 actual memory instances"}
    # Rebuild all PG shapes in this disposable copy to isolate the access test.
    editDelete -net {VDD VSS} -type Special
    set clear_signals 0
    if {[info exists ::env(D4_PG_CLEAR_SIGNALS)]} {set clear_signals $::env(D4_PG_CLEAR_SIGNALS)}
    if {$clear_signals} {
        # Disposable PG construction test only; never a routed-core result.
        editDelete -type Regular
        puts "D4_PG_SIGNAL_ROUTES_REMOVED=1 scope=PG_only_not_routed_core"
    }
    addRing -nets {VDD VSS} -type core_rings -follow core \
        -layer {top METAL5 bottom METAL5 left METAL6 right METAL6} -width 4 -spacing 2 -offset 3
    # Do not let stripe creation automatically descend into dense macro OBS.
    setAddStripeMode -stacked_via_bottom_layer METAL5 -stacked_via_top_layer METAL6
    addStripe -nets {VDD VSS} -layer METAL6 -direction vertical -width 4 -spacing 2 -set_to_set_distance 100 -start_offset 25
    verify_drc -check_only special -ignore_trial_route -limit 100000 -report $out/grid_only_drc.rpt
    set targets [dbGet -p2 top.insts.cell.name D4WROM6]
    set all_macros 0
    if {[info exists ::env(D4_PG_ALL_MACROS)]} {set all_macros $::env(D4_PG_ALL_MACROS)}
    if {$all_macros} {set targets [dbGet -p2 top.insts.cell.baseClass block]}
    if {[llength $targets] != [expr {$all_macros ? 19 : 1}]} {error "Unexpected access target inventory"}
    set method m4_sroute
    if {[info exists ::env(D4_PG_PROBE_METHOD)]} {set method $::env(D4_PG_PROBE_METHOD)}
    foreach target $targets {
      set inst [dbGet $target.name]
      if {$method in {m5_stripe m5_grid}} {
        set box [lindex [dbGet $target.box] 0]
        setAddStripeMode -stacked_via_bottom_layer METAL4 -stacked_via_top_layer METAL6
        set extra {}
        if {$method eq "m5_stripe"} {set extra {-over_pins 1 -pin_layer METAL4}}
        set access_file $out/macro_access_[llength [glob -nocomplain $out/macro_access_*.log]].log
        redirect $access_file {
            addStripe -nets {VDD VSS} -layer METAL5 -direction horizontal -width 4 -spacing 2 \
                -area $box -start_offset 25 -set_to_set_distance 100 {*}$extra
        }
        set f [open $access_file r];set access [read $f];close $f
        if {[string match {*\*\*ERROR*} $access] ||
                ![regexp {addStripe created ([0-9]+) wires} $access -> wires] || $wires==0} {
            error "Macro access created no usable stripe; inspect macro_access.log"
        }
        puts "D4_PG_MACRO_ACCESS instance=$inst wires=$wires"
      } elseif {$method eq "m4_sroute"} {
        sroute -nets {VDD VSS} -connect {blockPin} -inst $inst \
            -blockPin all -blockPinLayerRange {METAL4 METAL4} -layerChangeRange {METAL4 METAL6} \
            -blockPinTarget {stripe ring} -allowJogging 1 -allowLayerChange 1
      } else {error "Unknown PG access experiment"}
    }
    if {$all_macros} {
        sroute -nets {VDD VSS} -connect {corePin} -corePinTarget {stripe ring} \
            -layerChangeRange {METAL1 METAL6} -allowJogging 1 -allowLayerChange 1
    }
    redirect $out/connectivity_help.log {help verifyConnectivity}
    redirect $out/physical_connectivity.rpt {verifyConnectivity -type special -error 100000 -warning 100000}
    verify_drc -check_only special -ignore_trial_route -limit 100000 -report $out/one_macro_drc.rpt
    if {$all_macros && !$clear_signals} {
        verify_drc -check_only all -ignore_trial_route -limit 100000 -report $out/full_drc.rpt
        redirect $out/full_connectivity.rpt {verifyConnectivity -type all -error 100000 -warning 100000}
    }
    saveDesign $out/one_macro_pg.enc
    puts "D4_PG_ACCESS_PROBE_COMPLETE macros=$macro_count accessed=[llength $targets] method=$method acceptance_requires_DRC_and_pin_review"
}
if {[catch {pg_probe} message]} {puts "D4_PG_ACCESS_PROBE_FAIL=$message";exit 1}
exit
