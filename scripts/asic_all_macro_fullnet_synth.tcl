# A3 runs in its own report directory: private WORK, SVF, alib and command logs.
proc synth_main {} {
    set root [file normalize [file join [file dirname [info script]] ..]]
    set out [pwd]
    set corner tt
    if {[info exists ::env(D4_ASIC_CORNER)]} {set corner $::env(D4_ASIC_CORNER)}
    set period 10.0
    if {[info exists ::env(D4_ASIC_PERIOD_NS)]} {set period $::env(D4_ASIC_PERIOD_NS)}
    set libroot /opt/pdk/smic0.18um/DigitalIC
    if {$corner eq "tt"} {
        set db $libroot/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db
        set memcorner typical
    } elseif {$corner eq "ss"} {
        set db $libroot/5_SCC018UG_HD_RVT_lib_ss_v1p62_V0.3a/liberty/1.8v/scc018ug_hd_rvt_ss_v1p62_125c_basic.db
        set memcorner worst
    } else {error "Unsupported PVT"}
    set macro_libs [list $root/build/asic_macros/act_2048x128/RASP2048X16M16_${memcorner}.db \
        $root/build/asic_macros/act_1024x128/D4_ACT_1024X128_M8_${memcorner}.db]
    for {set bank 0} {$bank<8} {incr bank} {
        lappend macro_libs $root/build/asic_macros/weights/D4WROM${bank}/D4WROM${bank}_${memcorner}.db
        lappend macro_libs $root/build/asic_macros/residual/D4RROM${bank}/D4RROM${bank}_${memcorner}.db
    }
    foreach path [concat [list $db] $macro_libs] {if {![file exists $path]} {error "Missing real library $path"}}
    set_app_var target_library [list $db]
    set_app_var link_library [concat [list * $db] $macro_libs]
    set_app_var alib_library_analysis_path $out/alib
    file mkdir $out/WORK
    define_design_lib WORK -path $out/WORK
    set_svf $out/default.svf
    set_host_options -max_cores 8
    set source_paths [list build/asic_eval/native_asymmetric_logic_rom_mask_weights_mask_residual/d4_fullnet_eval.sv \
        rtl/asic/d4_rq_native_multiplier_lane.sv rtl/asic/d4_feature_banks_asymmetric.sv \
        rtl/asic/d4_smic180_sram.sv rtl/asic/d4_weight_rom_banks.sv rtl/asic/d4_residual_rom_banks.sv]
    set sources {}
    foreach source $source_paths {lappend sources $root/$source}
    analyze -define {SYNTHESIS D4_TECH_SRAM} -format sverilog $sources
    elaborate d4_fullnet_top
    current_design d4_fullnet_top
    if {![link]} {error "Unresolved full-core references"}
    set macros [get_cells -hierarchical -filter "ref_name =~ D4WROM* || ref_name =~ D4RROM* || ref_name == RASP2048X16M16 || ref_name == D4_ACT_1024X128_M8"]
    if {[sizeof_collection $macros]!=19} {error "Expected 16 programmed ROMs and 3 SRAMs"}
    set_dont_touch $macros true
    set f [open $out/macro_areas.tsv w]
    puts $f "instance\treference\tarea_um2"
    foreach_in_collection cell $macros {
        set ref [get_attribute $cell ref_name]
        set library_cell [get_lib_cells */$ref]
        if {[sizeof_collection $library_cell]!=1} {error "Ambiguous macro identity"}
        puts $f "[get_object_name $cell]\t$ref\t[get_attribute $library_cell area]"
    }
    close $f
    create_clock -name clk -period $period [get_ports clk]
    set_clock_uncertainty 0.2 [get_clocks clk]
    set ports [remove_from_collection [all_inputs] [get_ports clk]]
    set_input_delay -max 1.0 -clock clk $ports
    set_input_delay -min 0.1 -clock clk $ports
    set_output_delay -max 1.0 -clock clk [all_outputs]
    set_output_delay -min 0.1 -clock clk [all_outputs]
    set_input_transition 0.1 $ports
    set_load 0.01 [all_outputs]
    redirect $out/check_before.rpt {check_design}
    puts "D4_A3_ELABORATION_PASS programmed_ROMs=16 SRAMs=3"
    compile_ultra -no_autoungroup
    # Preserve expensive mapping before any diagnostic report can fail.
    write -format ddc -hierarchy -output $out/mapped.ddc
    write -format verilog -hierarchy -output $out/mapped.v
    write_sdc $out/constraints.sdc
    redirect $out/area.rpt {report_area -hierarchy}
    redirect $out/units.rpt {report_units}
    redirect $out/qor.rpt {report_qor}
    redirect $out/timing_max.rpt {report_timing -max_paths 20 -delay_type max}
    redirect $out/timing_min.rpt {report_timing -max_paths 20 -delay_type min}
    redirect $out/check.rpt {check_design}
    redirect $out/check_timing.rpt {check_timing}
    redirect $out/constraints.rpt {report_constraint -all_violators}
    write -format ddc -hierarchy -output $out/mapped.ddc
    write -format verilog -hierarchy -output $out/mapped.v
    write_sdc $out/constraints.sdc
    set f [open $out/area.rpt r];set text [read $f];close $f
    if {![regexp {Total cell area:\s+([0-9.eE+-]+)} $text -> area]} {error "Missing complete area"}
    set path [get_timing_paths -delay_type max -max_paths 1]
    set slack [get_attribute $path slack]
    if {![string is double -strict $slack]} {error "Missing setup result"}
    set f [open $out/result.json w]
    puts $f "{\"candidate\":\"A3\",\"corner\":\"$corner\",\"period_ns\":$period,\"cell_area_including_macros_um2\":$area,\"worst_setup_slack_ns\":$slack,\"programmed_ROMs\":16,\"SRAMs\":3,\"post_route\":false,\"power_claim\":false}"
    close $f
    puts "D4_A3_FULL_CORE_SYNTH_COMPLETE corner=$corner area_um2=$area setup_slack_ns=$slack"
}
if {[catch {synth_main} message]} {puts "D4_A3_FULL_CORE_SYNTH_FAIL=$message";quit}
quit
