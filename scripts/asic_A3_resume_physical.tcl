# Resume the same mapped/placed core at a defensible operating point.
# Preserve the 100MHz negative baseline; do not change network/RTL/MAC/cycles.
proc resume_main {} {
    set root [file normalize [file join [file dirname [info script]] ..]]
    set out [pwd]
    set period 20.0
    if {[info exists ::env(D4_ASIC_PERIOD_NS)]} {set period $::env(D4_ASIC_PERIOD_NS)}
    set prior $root/build/reports/asic_A3_physical_20261020/placed.enc.dat
    if {![file exists $prior]} {error "Completed placed checkpoint required"}
    setMultiCpuUsage -localCpu 8
    restoreDesign $prior d4_fullnet_top
    # Original placement used the tool's default 90nm optimization heuristic,
    # with real 180nm LEF/QRC/libraries throughout. Explicitly set it from here.
    setDesignMode -process 180
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
    update_constraint_mode -name CORE_MODE -sdc_files [list $out/core.sdc]
    set_analysis_view -setup {CORE_ss CORE_tt} -hold {CORE_ff}
    setAnalysisMode -analysisType onChipVariation -cppr both
    foreach corner {tt ss ff} {
        set_timing_derate -delay_corner DELAY_$corner -late 1.05
        set_timing_derate -delay_corner DELAY_$corner -early 0.95
    }
    timeDesign -preCTS -outDir $out/timing_preCTS
    set_ccopt_property buffer_cells {CLKBUFHDV2 CLKBUFHDV4 CLKBUFHDV8 CLKBUFHDV12 CLKBUFHDV16 CLKBUFHDV24}
    set_ccopt_property target_skew 0.1
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
    puts "D4_PHYSICAL_RESUME_EXECUTION_COMPLETE period_ns=$period acceptance_requires_timing_DRC_connectivity_and_equivalence"
}
if {[catch {resume_main} message]} {puts "D4_PHYSICAL_RESUME_EXECUTION_FAIL=$message";exit 1}
exit
