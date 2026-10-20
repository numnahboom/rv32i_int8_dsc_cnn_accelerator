# Operate only on the separate PG-only construction checkpoint.
proc trim_probe {} {
    set root [file normalize [file join [file dirname [info script]] ..]]
    set out [pwd]
    setMultiCpuUsage -localCpu 4
    restoreDesign $root/build/reports/asic_pg_m6_target_probe_20261020/one_macro_pg.enc.dat d4_fullnet_top
    puts "D4_PG_TRIM_SCOPE=PG_only_regular_routes_absent"
    editTrim -nets {VDD VSS}
    verify_drc -check_only special -ignore_trial_route -limit 100000 -report $out/pg_drc.rpt
    foreach net {VDD VSS} {
        redirect $out/connectivity_${net}.rpt {
            verifyConnectivity -net $net -type special -error 100000 -warning 100000
        }
    }
    saveDesign $out/trimmed_pg.enc
    puts "D4_PG_TRIM_EXECUTION_COMPLETE acceptance_requires_reports PG_only=1"
}
if {[catch {trim_probe} message]} {puts "D4_PG_TRIM_FAIL=$message";exit 1}
exit
