set root [file normalize [file join [file dirname [info script]] ..]]
set out_dir [file join $root build reports vivado_dual32_mac_local_island_ooc_20260830]
open_checkpoint [file join $out_dir dual32_mac_local_island_ooc.dcp]
report_timing_summary -delay_type min -max_paths 20 -file [file join $out_dir timing_summary_min.rpt]
puts "DUAL32_MIN_REPORT_DONE [file join $out_dir timing_summary_min.rpt]"
