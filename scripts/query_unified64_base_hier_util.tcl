set d [file normalize [file join [file dirname [info script]] .. build reports vivado_unified64_tile_engine_experiment_ooc_20260831 unified64_tile_engine_persistent_post_route.dcp]]
open_checkpoint $d
set o [file normalize [file join [file dirname [info script]] .. build reports vivado_unified64_tile_engine_experiment_ooc_20260831 hierarchy_util.txt]]
report_utilization -hierarchical -file $o
exit
