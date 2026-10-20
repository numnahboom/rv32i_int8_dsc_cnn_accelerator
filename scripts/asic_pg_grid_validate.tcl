# Bridge the PG-only result to an actual pre-CTS placed checkpoint.
proc validate_pg {} {
    set root [file normalize [file join [file dirname [info script]] ..]]
    set out [pwd]
    setMultiCpuUsage -localCpu 4
    restoreDesign $root/build/reports/asic_A3_physical_20261020/placed.enc.dat d4_fullnet_top
    editDelete -net {VDD VSS} -type Special
    editDelete -type Regular
    source $root/scripts/asic_pg_grid.tcl
    d4_build_pg_grid $out 19
    saveDesign $out/preCTS_pg.enc
    puts "D4_PRECTS_PG_VALIDATION_PASS scope=placed_PG_not_routed_core"
}
if {[catch {validate_pg} message]} {puts "D4_PRECTS_PG_VALIDATION_FAIL=$message";exit 1}
exit
