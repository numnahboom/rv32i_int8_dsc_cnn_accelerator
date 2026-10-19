# Environment-only equivalence smoke: original tiny 8x8 multiplier vs its gates.
set root [file normalize [file join [file dirname [info script]] ..]]
set synopsys_auto_setup true
set db /opt/pdk/smic0.18um/DigitalIC/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db
proc run_smoke {} {
    global root db
    read_db -technology_library $db
    read_verilog -r $root/build/reports/asic_dc_smoke_20261019/smoke.v
    set_top r:/WORK/asic_smoke
    read_verilog -i $root/build/reports/asic_dc_smoke_20261019/smoke_mapped.v
    set_top i:/WORK/asic_smoke
    match
    if {![verify]} {error "Tiny environment equivalence did not pass"}
    puts "ASIC_FM_ENVIRONMENT_SMOKE_PASS"
}
if {[catch {run_smoke} message]} {puts "ASIC_FM_ENVIRONMENT_SMOKE_FAIL=$message";exit 1}
exit
