# Tool/library-path preflight only; not a D4 physical result.
if {[llength [info commands getVersion]]} {puts "INNOVUS_VERSION=[getVersion]"}
set dk /opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a
set tech $dk/lef/tf/180MSE_1833/scc018ug_6m_1tma1.lef
set cells $dk/lef/macro/scc018ug_hd_rvt.lef
set rc $dk/voltagestorm/1.8v/scc018ug_hd_rvt_tt_v1p8_25c/techonly.cl/qrcTechFile_RCgen
foreach path [list $tech $cells $rc build/asic_macros/act_2048x128/RASP2048X16M16.lef] {
    if {![file readable $path]} {error "Missing physical input $path"}
    puts "PHYSICAL_INPUT_PRESENT=$path"
}
foreach command {create_rc_corner create_library_set init_design floorPlan placeInstance place_opt_design ccopt_design routeDesign verify_drc} {
    puts "PHYSICAL_COMMAND_PRESENT_${command}=[llength [info commands $command]]"
}
help create_rc_corner
help placeInstance
help report_timing
puts "D4_ASIC_INNOVUS_STARTUP_AND_PATHS_PASS"
exit
