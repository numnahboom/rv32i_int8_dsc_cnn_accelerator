# RTL-to-mapped or mapped-to-routed equivalence. Memories are technology black-box
# boundaries; actual programmed contents and protocols are checked separately.
proc formal_main {} {
    set root [file normalize [file join [file dirname [info script]] ..]]
    set out [pwd]
    set syn $root/build/reports/asic_A3_tt_20261020
    if {[info exists ::env(D4_SYNTH_TAG)]} {set syn $root/build/reports/$::env(D4_SYNTH_TAG)}
    set routed [expr {[info exists ::env(D4_FORMAL_ROUTED)] && $::env(D4_FORMAL_ROUTED)==1}]
    set ::synopsys_auto_setup true
    set db /opt/pdk/smic0.18um/DigitalIC/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db
    set libraries [list $db $root/build/asic_macros/act_2048x128/RASP2048X16M16_typical.db \
        $root/build/asic_macros/act_1024x128/D4_ACT_1024X128_M8_typical.db]
    for {set b 0} {$b<8} {incr b} {
        lappend libraries $root/build/asic_macros/weights/D4WROM${b}/D4WROM${b}_typical.db
        lappend libraries $root/build/asic_macros/residual/D4RROM${b}/D4RROM${b}_typical.db
    }
    foreach path [concat $libraries [list $syn/mapped.v $syn/default.svf]] {
        if {![file readable $path]} {error "Missing same-source mapped input $path"}
    }
    if {!$routed} {set_svf $syn/default.svf}
    read_db -technology_library $libraries
    set sources {}
    foreach path {build/asic_eval/native_asymmetric_logic_rom_mask_weights_mask_residual/d4_fullnet_eval.sv \
            rtl/asic/d4_rq_native_multiplier_lane.sv rtl/asic/d4_feature_banks_asymmetric.sv \
            rtl/asic/d4_smic180_sram.sv rtl/asic/d4_weight_rom_banks.sv rtl/asic/d4_residual_rom_banks.sv} {
        lappend sources $root/$path
    }
    if {$routed} {
        read_verilog -r $syn/mapped.v
    } else {
        read_sverilog -r -define {SYNTHESIS D4_TECH_SRAM} $sources
    }
    set_top r:/WORK/d4_fullnet_top
    if {$routed} {
        set tag asic_A3_physical_20261020
        if {[info exists ::env(D4_PHYSICAL_TAG)]} {set tag $::env(D4_PHYSICAL_TAG)}
        read_verilog -i $root/build/reports/$tag/routed.v
    } else {read_verilog -i $syn/mapped.v}
    set_top i:/WORK/d4_fullnet_top
    match
    redirect $out/unmatched.rpt {report_unmatched_points}
    # A black-box report is diagnostic only; do not hide verification failure.
    catch {redirect $out/black_boxes.rpt {report_black_boxes}}
    if {![verify]} {
        redirect $out/failing.rpt {report_failing_points}
        catch {save_session -replace $out/failed_session}
        error "Full A3 RTL-to-mapped verification did not pass"
    }
    catch {redirect $out/dont_verify.rpt {report_dont_verify_points}}
    catch {redirect $out/constants.rpt {report_constants}}
    if {$routed} {
        puts "D4_A3_MAPPED_TO_ROUTED_FORMAL_PASS scope=logic_with_identical_19_memory_boundaries"
    } else {puts "D4_A3_RTL_TO_MAPPED_FORMAL_PASS scope=logic_with_identical_19_memory_boundaries"}
}
if {[catch {formal_main} message]} {puts "D4_A3_FORMAL_FAIL=$message";exit 1}
exit
