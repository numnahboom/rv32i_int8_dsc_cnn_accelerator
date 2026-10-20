# Shared, checked P/G construction after placement and before CTS/signal route.
# Caller must remove trial routes first; this helper never edits regular wires.
proc d4_build_pg_grid {out expected_macros} {
    file mkdir $out
    globalNetConnect VDD -type pgpin -pin VDD -all
    globalNetConnect VSS -type pgpin -pin VSS -all
    globalNetConnect VSS -type pgpin -pin GND -all -override
    globalNetConnect VDD -type tiehi -all
    globalNetConnect VSS -type tielo -all
    set macros [dbGet -p2 top.insts.cell.baseClass block]
    if {$macros eq "0x0"} {set macros {}}
    if {[llength $macros]!=$expected_macros} {error "Wrong actual macro inventory for PG construction"}
    set f [open $out/pg_macro_inventory.rpt w]
    foreach inst $macros {
        puts $f "INSTANCE [dbGet $inst.name]"
        set pins [dbGet $inst.pgInstTerms]
        if {$pins eq "0x0" || [llength $pins]!=2} {error "Missing macro PG terminals"}
        foreach pin $pins {
            set name [dbGet $pin.name];set net [dbGet $pin.net.name]
            if {$name eq "VDD"} {set expected VDD} elseif {$name eq "GND"} {set expected VSS} \
                else {error "Unexpected actual macro PG terminal"}
            if {$net ne $expected} {error "Incorrect macro PG net"}
            puts $f "PIN $name NET $net"
        }
    }
    close $f
    addRing -nets {VDD VSS} -type core_rings -follow core \
        -layer {top METAL5 bottom METAL5 left METAL6 right METAL6} -width 4 -spacing 2 -offset 3
    setAddStripeMode -stacked_via_bottom_layer METAL5 -stacked_via_top_layer METAL6
    addStripe -nets {VDD VSS} -layer METAL6 -direction vertical -width 4 -spacing 2 \
        -set_to_set_distance 100 -start_offset 25
    # Core stacks must precede the macro M5 straps. Otherwise ViaGen can extend
    # macro contact stacks down into the dense lower-metal SRAM obstructions.
    setSrouteMode -viaConnectToShape {ring stripe followpin}
    sroute -nets {VDD VSS} -connect {corePin} -corePinTarget {stripe ring} \
        -layerChangeRange {METAL1 METAL6} -targetViaLayerRange {METAL6 METAL6} \
        -stripeLayerRange {METAL6 METAL6} -allowJogging 1 -allowLayerChange 1
    editTrim -nets {VDD VSS}
    set index 0
    foreach inst $macros {
        set box [lindex [dbGet $inst.box] 0]
        setAddStripeMode -stacked_via_bottom_layer METAL4 -stacked_via_top_layer METAL6
        set access_file $out/pg_macro_access_${index}.log
        redirect $access_file {
            addStripe -nets {VDD VSS} -layer METAL5 -direction horizontal -width 4 -spacing 2 \
                -area $box -start_offset 25 -set_to_set_distance 100
        }
        set f [open $access_file r];set text [read $f];close $f
        if {[string match {*\*\*ERROR*} $text] ||
                ![regexp {addStripe created ([0-9]+) wires} $text -> wires] || $wires==0} {
            error "No usable upper-metal PG strap at [dbGet $inst.name]"
        }
        puts "D4_PG_MACRO_STRAP instance=[dbGet $inst.name] wires=$wires"
        incr index
    }
    editTrim -nets {VDD VSS}
    verify_drc -check_only special -ignore_trial_route -limit 100000 -report $out/pg_drc.rpt
    set f [open $out/pg_drc.rpt r];set text [read $f];close $f
    if {![string match {*No DRC violations were found*} $text]} {error "PG geometry is not DRC-clean"}
    foreach net {VDD VSS} {
        set report $out/pg_connectivity_${net}.rpt
        redirect $report {verifyConnectivity -net $net -type special -error 100000 -warning 100000}
        set f [open $report r];set text [read $f];close $f
        if {![regexp {Verification Complete\s*:\s*0 Viols\.\s*0 Wrngs\.} $text]} {
            error "PG physical connectivity failed for $net"
        }
    }
    puts "D4_PG_GRID_CONSTRUCTION_PASS macros=$expected_macros special_DRC=0 VDD_connectivity=0 VSS_connectivity=0 scope=preCTS_PG_only"
}
