# Report-only recovery of the completed A3 mapping: no compile/optimization.
proc report_saved {} {
    set root [file normalize [file join [file dirname [info script]] ..]]
    set out [pwd]
    set db /opt/pdk/smic0.18um/DigitalIC/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db
    set libs [list $db $root/build/asic_macros/act_2048x128/RASP2048X16M16_typical.db \
        $root/build/asic_macros/act_1024x128/D4_ACT_1024X128_M8_typical.db]
    for {set b 0} {$b<8} {incr b} {
        lappend libs $root/build/asic_macros/weights/D4WROM${b}/D4WROM${b}_typical.db
        lappend libs $root/build/asic_macros/residual/D4RROM${b}/D4RROM${b}_typical.db
    }
    set_app_var target_library [list $db]
    set_app_var link_library [concat [list *] $libs]
    read_ddc $out/mapped.ddc
    current_design d4_fullnet_top
    if {![link]} {error "Saved mapping has unresolved references"}
    redirect $out/check_timing_recovered.rpt {check_timing}
    redirect $out/constraints_recovered.rpt {report_constraint -all_violators}
    redirect $out/area_recovered.rpt {report_area -hierarchy}
    redirect $out/timing_max_recovered.rpt {report_timing -max_paths 20 -delay_type max}
    redirect $out/timing_min_recovered.rpt {report_timing -max_paths 20 -delay_type min}
    redirect $out/check_recovered.rpt {check_design}
    set f [open $out/area_recovered.rpt r];set text [read $f];close $f
    if {![regexp {Total cell area:\s+([0-9.eE+-]+)} $text -> area]} {error "Missing full area"}
    set slack [get_attribute [get_timing_paths -delay_type max -max_paths 1] slack]
    set f [open $out/result.json w]
    puts $f "{\"candidate\":\"A3\",\"corner\":\"tt\",\"period_ns\":10.0,\"cell_area_including_macros_um2\":$area,\"worst_setup_slack_ns\":$slack,\"programmed_ROMs\":16,\"SRAMs\":3,\"post_route\":false,\"power_claim\":false,\"reports_recovered_from_saved_DDC_without_optimization\":true}"
    close $f
    puts "D4_A3_SAVED_MAPPING_REPORT_PASS area_um2=$area setup_slack_ns=$slack"
}
if {[catch {report_saved} message]} {puts "D4_A3_SAVED_MAPPING_REPORT_FAIL=$message";quit}
quit
