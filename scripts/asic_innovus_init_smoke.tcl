# Initialize actual physical libraries using the previously synthesized tiny
# multiplier environment test. This is not a D4 timing/area result.
proc smoke_main {} {
    set out build/reports/asic_innovus_init_smoke_20261020
    file mkdir $out
    set dk /opt/pdk/smic0.18um/DigitalIC/SCC018UG_HD_RVT_DK_V0.3a
    set libroot /opt/pdk/smic0.18um/DigitalIC
    set std $libroot/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.lib
    set ram build/asic_macros/act_2048x128/RASP2048X16M16_typical.lib
    set rc $dk/voltagestorm/1.8v/scc018ug_hd_rvt_tt_v1p8_25c/techonly.cl/qrcTechFile_RCgen
    set f [open $out/smoke.sdc w]
    puts $f {create_clock -name clk -period 10 [get_ports clk]}
    puts $f {set_clock_uncertainty 0.2 [get_clocks clk]}
    puts $f {set_input_delay 1 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]}
    puts $f {set_output_delay 1 -clock clk [all_outputs]}
    close $f
    # Innovus 19 requires analysis-view selection inside init_design's MMMC
    # load, rather than before the design is initialized.
    set f [open $out/views.tcl w]
    puts $f [list create_library_set -name D4_SMOKE_LIB -timing [list $std $ram]]
    puts $f [list create_rc_corner -name D4_SMOKE_RC -qx_tech_file $rc -T 25]
    puts $f {create_delay_corner -name D4_SMOKE_DELAY -library_set D4_SMOKE_LIB -rc_corner D4_SMOKE_RC}
    puts $f [list create_constraint_mode -name D4_SMOKE_MODE -sdc_files [list $out/smoke.sdc]]
    puts $f {create_analysis_view -name D4_SMOKE_VIEW -constraint_mode D4_SMOKE_MODE -delay_corner D4_SMOKE_DELAY}
    puts $f {set_analysis_view -setup D4_SMOKE_VIEW -hold D4_SMOKE_VIEW}
    close $f
    set ::init_mmmc_file $out/views.tcl
    set ::init_verilog build/reports/asic_dc_smoke_20261019/smoke_mapped.v
    set ::init_top_cell asic_smoke
    set ::init_lef_file [list $dk/lef/tf/180MSE_1833/scc018ug_6m_1tma1.lef \
        $dk/lef/macro/scc018ug_hd_rvt.lef build/asic_macros/act_2048x128/RASP2048X16M16_digital.lef]
    set ::init_pwr_net VDD
    set ::init_gnd_net VSS
    init_design
    puts "PHYSICAL_SITES=[dbGet head.sites.name]"
    set macros [dbGet head.libCells.name RASP2048X16M16 -p]
    puts "PHYSICAL_SRAM_SIZE=[dbGet $macros.size]"
    puts "PHYSICAL_TIE_NAMES=[dbGet head.libCells.name *TIE*]"
    puts "PHYSICAL_LOGIC_NAMES=[dbGet head.libCells.name *LOGIC*]"
    puts "PHYSICAL_CLOCK_BUFFERS=[dbGet head.libCells.name *CLKBUF*]"
    saveDesign $out/initialized.enc
    puts "D4_ASIC_INNOVUS_LIBRARY_INIT_SMOKE_PASS"
}
if {[catch {smoke_main} message]} {puts "D4_ASIC_INNOVUS_LIBRARY_INIT_SMOKE_FAIL=$message"; exit 1}
exit
