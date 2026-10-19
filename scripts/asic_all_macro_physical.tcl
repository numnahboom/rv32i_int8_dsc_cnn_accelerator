# Actual SMIC physical flow. D4_PHYSICAL_SMOKE=1 exercises tool commands only
# on the old tiny multiplier; it must never be reported as a D4 result.
proc physical_main {} {
    set root [file normalize [file join [file dirname [info script]] ..]]
    set out [pwd]
    set period 10.0
    if {[info exists ::env(D4_ASIC_PERIOD_NS)]} {set period $::env(D4_ASIC_PERIOD_NS)}
    set smoke [expr {[info exists ::env(D4_PHYSICAL_SMOKE)] && $::env(D4_PHYSICAL_SMOKE)==1}]
    set dk /opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a
    set libroot /opt/pdk/smic0.18um/DigitalIC
    set f [open $out/core.sdc w]
    puts $f [format {create_clock -name clk -period %s [get_ports clk]} $period]
    puts $f {set_clock_uncertainty 0.2 [get_clocks clk]}
    puts $f {set_input_delay -max 1.0 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]}
    puts $f {set_input_delay -min 0.1 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]}
    puts $f {set_output_delay -max 1.0 -clock clk [all_outputs]}
    puts $f {set_output_delay -min 0.1 -clock clk [all_outputs]}
    puts $f {set_input_transition 0.1 [remove_from_collection [all_inputs] [get_ports clk]]}
    puts $f {set_load 0.01 [all_outputs]}
    close $f
    set f [open $out/views.tcl w]
    foreach {corner voltage temperature memcorner} {tt 1p8 25 typical ss 1p62 125 worst ff 1p98 0 best} {
        set std [glob $libroot/*/liberty/1.8v/scc018ug_hd_rvt_${corner}_v${voltage}_${temperature}c_basic.lib]
        if {[llength $std]!=1} {error "Ambiguous physical standard-cell corner"}
        set libs $std
        lappend libs $root/build/asic_macros/act_2048x128/RASP2048X16M16_${memcorner}.lib
        lappend libs $root/build/asic_macros/act_1024x128/D4_ACT_1024X128_M8_${memcorner}.lib
        if {!$smoke} {
            for {set b 0} {$b<8} {incr b} {lappend libs $root/build/asic_macros/weights/D4WROM${b}/D4WROM${b}_${memcorner}.lib
                lappend libs $root/build/asic_macros/residual/D4RROM${b}/D4RROM${b}_${memcorner}.lib}
        }
        foreach filename $libs {if {![file readable $filename]} {error "Missing physical timing library"}}
        set qrc $dk/voltagestorm/1.8v/scc018ug_hd_rvt_${corner}_v${voltage}_${temperature}c/techonly.cl/qrcTechFile_RCgen
        puts $f [list create_library_set -name LIB_$corner -timing $libs]
        puts $f [list create_rc_corner -name RC_$corner -qx_tech_file $qrc -T $temperature]
        puts $f [list create_delay_corner -name DELAY_$corner -library_set LIB_$corner -rc_corner RC_$corner]
    }
    puts $f [list create_constraint_mode -name CORE_MODE -sdc_files [list $out/core.sdc]]
    foreach corner {tt ss ff} {puts $f [list create_analysis_view -name CORE_$corner -constraint_mode CORE_MODE -delay_corner DELAY_$corner]}
    puts $f {set_analysis_view -setup {CORE_ss CORE_tt} -hold {CORE_ff}}
    close $f
    set ::init_mmmc_file $out/views.tcl
    set ::init_top_cell d4_fullnet_top
    set ::init_verilog $root/build/reports/asic_A3_tt_20261020/mapped.v
    set ::init_lef_file [list $dk/lef/tf/180MSE_1833/scc018ug_6m_1tma1.lef \
        $dk/lef/macro/scc018ug_hd_rvt.lef \
        $root/build/asic_macros/act_2048x128/RASP2048X16M16_digital.lef \
        $root/build/asic_macros/act_1024x128/D4_ACT_1024X128_M8_digital.lef]
    if {$smoke} {
        set ::init_top_cell asic_smoke
        set ::init_verilog $root/build/reports/asic_dc_smoke_20261019/smoke_mapped.v
    } else {
        if {![file readable $::init_verilog]} {error "Accepted complete-core synthesis required first"}
        for {set b 0} {$b<8} {incr b} {
            lappend ::init_lef_file $root/build/asic_macros/weights/D4WROM${b}/D4WROM${b}_digital.lef
            lappend ::init_lef_file $root/build/asic_macros/residual/D4RROM${b}/D4RROM${b}_digital.lef
        }
    }
    set ::init_pwr_net VDD
    set ::init_gnd_net VSS
    setMultiCpuUsage -localCpu 8
    setDesignMode -process 180
    init_design
    setAnalysisMode -analysisType onChipVariation -cppr both
    foreach corner {tt ss ff} {
        set_timing_derate -delay_corner DELAY_$corner -late 1.05
        set_timing_derate -delay_corner DELAY_$corner -early 0.95
    }
    if {$smoke} {
        set side 150.0
    } else {
        set f [open $root/build/reports/asic_A3_tt_20261020/result.json r];set summary [read $f];close $f
        if {![regexp {"cell_area_including_macros_um2":([0-9.eE+-]+)} $summary -> area]} {error "Missing full-core area"}
        set side [expr {max(sqrt($area/0.60),3450.0)}]
    }
    floorPlan -site hd_CoreSite -s $side $side 50 50 50 50
    if {!$smoke} {
        set box [dbGet top.fPlan.coreBox]
        if {[llength $box]==1} {set box [lindex $box 0]}
        set x0 [lindex $box 0];set y0 [lindex $box 1]
        set deep [lsort [dbGet [dbGet -p2 top.insts.cell.name RASP2048X16M16].name]]
        set shallow [dbGet [dbGet -p2 top.insts.cell.name D4_ACT_1024X128_M8].name]
        if {[llength $deep]!=2 || [llength $shallow]!=1} {error "Unexpected SRAM placement inventory"}
        set y [expr {$y0+50.0}]
        foreach inst [list [lindex $deep 0] $shallow [lindex $deep 1]] height {757.070 433.230 757.070} {
            placeInstance $inst [expr {$x0+50.0}] $y R0 -fixed
            set y [expr {$y+$height+30.0}]
        }
        set y [expr {$y0+50.0}]
        for {set b 0} {$b<8} {incr b} {
            set ref D4WROM${b}
            set instance [dbGet [dbGet -p2 top.insts.cell.name $ref].name]
            set size [lindex [dbGet [dbGet -p head.libCells.name $ref].size] 0]
            if {[llength $instance]!=1} {error "Unexpected programmed ROM inventory"}
            placeInstance $instance [expr {$x0+2206.26}] $y R0 -fixed
            set y [expr {$y+[lindex $size 1]+30.0}]
            if {$y>$y0+$side-30.0} {error "Macro column exceeds core boundary"}
        }
        for {set b 0} {$b<8} {incr b} {
            set ref D4RROM${b}
            set instance [dbGet [dbGet -p2 top.insts.cell.name $ref].name]
            set size [lindex [dbGet [dbGet -p head.libCells.name $ref].size] 0]
            if {[llength $instance]!=1} {error "Unexpected residual ROM inventory"}
            set x [expr {$x0+50.0+($b%4)*([lindex $size 0]+30.0)}]
            set y [expr {$y0+2107.37+($b/4)*([lindex $size 1]+30.0)}]
            if {$x+[lindex $size 0]>$x0+2150 || $y+[lindex $size 1]>$y0+$side-30} {error "Residual ROM packing exceeds allocated region"}
            placeInstance $instance $x $y R0 -fixed
        }
        addHaloToBlock 10 10 10 10 -allBlock
    }
    globalNetConnect VDD -type pgpin -pin VDD -all
    globalNetConnect VSS -type pgpin -pin VSS -all
    globalNetConnect VDD -type tiehi -all
    globalNetConnect VSS -type tielo -all
    addRing -nets {VDD VSS} -type core_rings -follow core \
        -layer {top METAL5 bottom METAL5 left METAL6 right METAL6} -width 4 -spacing 2 -offset 3
    addStripe -nets {VDD VSS} -layer METAL6 -direction vertical -width 4 -spacing 2 -set_to_set_distance 100 -start_offset 25
    sroute -nets {VDD VSS} -connect {blockPin corePin} -allowJogging 1 -allowLayerChange 1
    setPlaceMode -place_global_place_io_pins true
    place_opt_design
    saveDesign $out/placed.enc
    set_ccopt_property buffer_cells {CLKBUFHDV2 CLKBUFHDV4 CLKBUFHDV8 CLKBUFHDV12 CLKBUFHDV16 CLKBUFHDV24}
    set_ccopt_property target_skew 0.1
    # The actual SS library reports a 0.218 ns minimum viable leaf/trunk target.
    set_ccopt_property target_max_trans 0.25
    create_ccopt_clock_tree_spec
    ccopt_design
    optDesign -postCTS
    optDesign -postCTS -hold
    saveDesign $out/postcts.enc
    setNanoRouteMode -routeTopRoutingLayer 6
    setNanoRouteMode -routeBottomRoutingLayer 1
    setNanoRouteMode -routeWithTimingDriven true
    routeDesign
    optDesign -postRoute
    optDesign -postRoute -hold
    saveDesign $out/routed.enc
    saveNetlist $out/routed.v
    timeDesign -postRoute -outDir $out/timing_setup
    timeDesign -postRoute -hold -outDir $out/timing_hold
    redirect $out/connectivity.rpt {verifyConnectivity -type all}
    verify_drc -report $out/drc.rpt
    rcOut -spef $out/routed.spef
    puts "D4_PHYSICAL_EXECUTION_COMPLETE smoke=$smoke acceptance_requires_timing_DRC_and_connectivity_review"
}
if {[catch {physical_main} message]} {puts "D4_PHYSICAL_EXECUTION_FAIL=$message";exit 1}
exit
