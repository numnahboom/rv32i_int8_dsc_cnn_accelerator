# Environment-only smoke test. This is not D4 PPA.
set out build/reports/asic_dc_smoke_20261019
file mkdir $out
set lib /opt/pdk/smic0.18um/SCC018UG_HD_RVT_V0p3a/liberty/1.8v/scc018ug_hd_rvt_tt_v1p8_25c_basic.db
if {![file exists $lib]} {error "Missing actual standard cell DB"}
set_app_var target_library [list $lib]
set_app_var link_library [concat * $target_library]
set f [open $out/smoke.v w]
puts $f {module asic_smoke(input clk, input [7:0] a,b, output reg [15:0] q); always @(posedge clk) q<=a*b; endmodule}
close $f
analyze -format verilog $out/smoke.v
elaborate asic_smoke
link
create_clock -name clk -period 10 [get_ports clk]
set_input_delay 1 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 1 -clock clk [all_outputs]
compile
redirect $out/area.rpt {report_area}
redirect $out/timing.rpt {report_timing}
redirect $out/check.rpt {check_design}
write -format verilog -hierarchy -output $out/smoke_mapped.v
puts "ASIC_DC_SMOKE_PASS"
quit
