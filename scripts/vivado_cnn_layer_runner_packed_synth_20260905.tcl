# Focused current-source synthesis screen for the real packed-weight runner.
# This intentionally stops after synth_design: no placement, routing, OOC
# timing closure, or full-network closure is implied by this artifact.
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_cnn_layer_runner_packed_synth_20260905]]
file mkdir $out
set part xc7z020clg400-1
set top cnn_layer_runner
set packed_generic USE_UNIFIED64_DS=1
set sf [open [file join $out run_settings.txt] w]
puts $sf "tool=Vivado 2025.2"
puts $sf "part=$part"
puts $sf "top=$top"
puts $sf "mode=synth-only"
puts $sf "generic=$packed_generic"
puts $sf "clock_period_ns=8.000"
puts $sf "packed_descriptor_flag=FLAG_PACKED_WEIGHTS bit7"
puts $sf "packed_loader=cnn_layer_runner -> ds_block_tile_engine_new -> pw_weight_buffer_bram"
close $sf

set files {
    rtl/common/round_shift.v
    rtl/common/saturate_int8.v
    rtl/common/requant_activation_core.v
    rtl/cnn/requant_activation_unit.v
    rtl/cnn/requant_activation_vector4.v
    rtl/cnn/requant_activation_stream4.v
    rtl/cnn/requant_activation_pipeline.v
    rtl/cnn/requant_product_pipeline.v
    rtl/cnn/systolic_pe.v
    rtl/cnn/pw_systolic_array_8x8.v
    rtl/cnn/pw_direct_8x8_dsp.v
    rtl/cnn/pw_direct_8x8_dsp_rowbank.v
    rtl/cnn/dw_line_buffer.v
    rtl/cnn/dw_mac_lanes.v
    rtl/cnn/dw_tile_buffer_bram.v
    rtl/cnn/ds_input_tile_buffer_bram.v
    rtl/cnn/pw_weight_buffer_bram.v
    rtl/cnn/dw_tile_fusion_engine_new.v
    rtl/cnn/dw_tile_fusion_engine_vector4.v
    rtl/cnn/unified64_tile_engine_experiment.v
    rtl/cnn/unified64_shared_compute_array.v
    rtl/cnn/ds_block_tile_engine_new.v
    rtl/cnn/ds_persistent_pw_row_feed.v
    rtl/cnn/conv3x3_stem_engine_new.v
    rtl/cnn/stem_weight_store_packed64.v
    rtl/cnn/stem_unified64_streaming.v
    rtl/cnn/gap_unit_new.v
    rtl/cnn/fc_unit_new.v
    rtl/cnn/tile_scheduler.v
    rtl/cnn/feature_sram_bank.v
    rtl/cnn/feature_sram_pingpong.v
    rtl/cnn/status_counter.v
    rtl/cnn/descriptor_fetch.v
    rtl/cnn/cnn_layer_runner.v
}
set manifest [open [file join $out source_manifest.txt] w]
foreach f $files {
    set p [file normalize [file join $root $f]]
    puts $manifest $p
    read_verilog -sv $p
}
close $manifest

synth_design -top $top -part $part -mode out_of_context \
    -flatten_hierarchy rebuilt -directive RuntimeOptimized \
    -generic [list $packed_generic]
create_clock -name clk -period 8.000 [get_ports clk]

report_utilization -hierarchical -file [file join $out utilization_synth_hierarchical.txt]
report_utilization -file [file join $out utilization_synth.txt]
report_timing_summary -delay_type max -max_paths 100 \
    -file [file join $out timing_summary_synth_estimate.txt]
report_compile_order -used_in synthesis \
    -file [file join $out compile_order_synthesis.txt]

# Query the post-synthesis design for the packed loader hierarchy and preserve
# the exact source/generic contract alongside the DCP.  Query failures are
# recorded but do not mask the synthesis result.
set ef [open [file join $out packed_loader_query.txt] w]
puts $ef "design=[get_property NAME [current_design]]"
puts $ef "generic=$packed_generic"
puts $ef "source_files=[llength [get_files -all]]"
foreach pattern {*cnn_layer_runner.v *ds_block_tile_engine_new.v *pw_weight_buffer_bram.v} {
    set fs [get_files -all $pattern]
    puts $ef "file_query=$pattern count=[llength $fs]"
    foreach f $fs { puts $ef "  [get_property NAME $f]" }
}
set packed_cells [get_cells -hierarchical -filter {ORIG_REF_NAME =~ *pw_weight_buffer_bram* || REF_NAME =~ *pw_weight_buffer_bram*}]
puts $ef "packed_buffer_cells=[llength $packed_cells]"
foreach c $packed_cells {
    puts $ef "cell=[get_property NAME $c] ref=[get_property REF_NAME $c] orig=[get_property ORIG_REF_NAME $c]"
}
set packed_nets [get_nets -hierarchical -filter {NAME =~ *cfg_weight_word* || NAME =~ *packed_weight*}]
puts $ef "packed_named_nets=[llength $packed_nets]"
foreach n $packed_nets { puts $ef "net=[get_property NAME $n]" }
close $ef

write_checkpoint -force [file join $out cnn_layer_runner_packed_synth.dcp]
puts "PACKED_RUNNER_SYNTH_DONE out=$out"
exit
