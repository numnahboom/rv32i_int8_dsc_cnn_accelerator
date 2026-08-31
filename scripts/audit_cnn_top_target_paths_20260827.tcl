set dcp [lindex $argv 0]
set outdir [lindex $argv 1]
file mkdir $outdir
open_checkpoint $dcp
report_timing -delay_type max -from [get_pins -hierarchical *store_idx_reg*/C] -to [get_pins -hierarchical *ENBWREN] -max_paths 20 -nworst 20 -sort_by slack -path_type full -input_pins -nets -file [file join $outdir store_idx_to_outbuf_full.rpt]
report_timing -delay_type max -from [get_pins -hierarchical *tile_h_start_reg*/C] -to [get_pins -hierarchical *tiled_store_addr_current_reg*/D] -max_paths 20 -nworst 20 -sort_by slack -path_type full -input_pins -nets -file [file join $outdir tile_h_to_store_addr_full.rpt]
close_design
puts AUDIT_TARGET_DONE
