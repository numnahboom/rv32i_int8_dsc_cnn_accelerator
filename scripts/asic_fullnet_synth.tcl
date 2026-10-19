# Fixed D4 ASIC core: three real SRAM macros + explicit constant parameter ROM
# logic. No FPGA initialization, unresolved memory blackbox, or DSP primitive.
set corner tt
if {[info exists env(D4_ASIC_CORNER)]} {set corner $env(D4_ASIC_CORNER)}
set period 10.0
if {[info exists env(D4_ASIC_PERIOD_NS)]} {set period $env(D4_ASIC_PERIOD_NS)}
set out build/reports/asic_fullnet_${corner}_20261019
file mkdir $out
set libroot /opt/pdk/smic0.18um/DigitalIC
if {$corner eq "tt"} {
    set db $libroot/6_SCC018UG_HD_RVT_lib_tt_v1p8_V0.3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db
    set ram build/asic_macros/act_2048x128/RASP2048X16M16_typical.db
} elseif {$corner eq "ss"} {
    set db $libroot/5_SCC018UG_HD_RVT_lib_ss_v1p62_V0.3a/liberty/1.8v/scc018ug_hd_rvt_ss_v1p62_125c_basic.db
    set ram build/asic_macros/act_2048x128/RASP2048X16M16_worst.db
} else {error "Unsupported corner"}
if {![file exists $ram]} {error "Real compiled SRAM database required"}
set_app_var target_library [list $db]
set_app_var link_library [list * $db $ram]
set_host_options -max_cores 8
analyze -define {SYNTHESIS D4_TECH_SRAM} -format sverilog [list \
    build/asic_eval/native_banked_logic_rom/d4_fullnet_eval.sv \
    rtl/asic/d4_rq_native_multiplier_lane.sv rtl/asic/d4_feature_banks.sv \
    rtl/asic/d4_smic180_sram.sv]
elaborate d4_fullnet_top
current_design d4_fullnet_top
if {![link]} {error "Unresolved full-network references"}
set macros [get_cells -hierarchical -filter "ref_name == RASP2048X16M16"]
if {[sizeof_collection $macros] != 3} {error "Expected exactly 3 technology SRAMs"}
set_dont_touch $macros true
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
compile_ultra -no_autoungroup
redirect $out/area.rpt {report_area -hierarchy}
redirect $out/units.rpt {report_units}
redirect $out/qor.rpt {report_qor}
redirect $out/timing_max.rpt {report_timing -max_paths 20 -delay_type max}
redirect $out/timing_min.rpt {report_timing -max_paths 20 -delay_type min}
redirect $out/constraints.rpt {report_constraint -all_violators}
redirect $out/check.rpt {check_design}
redirect $out/check_timing.rpt {check_timing -verbose}
redirect $out/resources.rpt {report_resources -hierarchy}
redirect $out/power_vectorless.rpt {report_power}
write -format ddc -hierarchy -output $out/mapped.ddc
write -format verilog -hierarchy -output $out/mapped.v
write_sdc $out/constraints.sdc
set f [open $out/area.rpt r]
set area_report [read $f]
close $f
if {![regexp {Total cell area:\s+([0-9.eE+-]+)} $area_report -> area]} {error "Missing complete mapped area"}
set path [get_timing_paths -delay_type max -max_paths 1]
set slack [get_attribute $path slack]
if {![string is double -strict $slack]} {error "Missing full-network setup slack"}
set f [open $out/result.json w]
puts $f "{\"corner\":\"$corner\",\"period_ns\":$period,\"cell_area_including_SRAM_um2\":$area,\"worst_setup_slack_ns\":$slack,\"SRAM_macros\":3,\"scope\":\"complete_128bit_D4_core_synthesis_only\",\"power_claim\":false,\"post_route\":false}"
close $f
puts "D4_ASIC_FULLNET_SYNTH_COMPLETE corner=$corner area_um2=$area slack_ns=$slack"
quit
