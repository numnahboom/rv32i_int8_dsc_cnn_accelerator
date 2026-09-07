# Read-only post-route hierarchy query for the M1.1-A diagnostic report.
set dcp [file normalize [file join [file dirname [info script]] .. build reports m11a_runtime_dw_pw_core_ooc_8ns m11a_runtime_dw_pw_core_ooc_8ns_post_route.dcp]]
open_checkpoint $dcp
set out [file normalize [file join [file dirname [info script]] .. build reports m11a_runtime_dw_pw_core_ooc_8ns post_route_structure_query.txt]]
set fh [open $out w]
proc emit {fh line} { puts $line; puts $fh $line }
set dsp [get_cells -hier -filter {REF_NAME == DSP48E1}]
emit $fh "DSP_COUNT=[llength $dsp]"
set dw 0
set pw 0
set other 0
foreach c $dsp {
    set n [get_property NAME $c]
    if {[string match "*dw16*" $n]} {
        incr dw
    } elseif {[string match "*pw64*" $n]} {
        incr pw
    } else {
        incr other
    }
}
emit $fh "DSP_BY_HIER dw16=$dw pw64=$pw other=$other"
set mac_cells [get_cells -hier -filter {REF_NAME =~ "m11a_pw_mac_cell*"}]
set mac_dsp [get_cells -hier -filter {REF_NAME == DSP48E1 && NAME =~ "*GEN_PW64_MAC*" && NAME !~ "*pwrq4*"}]
set mac_carry [get_cells -hier -filter {REF_NAME == CARRY4 && NAME =~ "*GEN_PW64_MAC*"}]
set mac_lut [get_cells -hier -filter {IS_PRIMITIVE && NAME =~ "*GEN_PW64_MAC*" && REF_NAME =~ "LUT*"}]
set dw_mac [get_cells -hier -filter {REF_NAME == DSP48E1 && NAME =~ "*GEN_DW16_MAC*"}]
set dw_rq [get_cells -hier -filter {REF_NAME == DSP48E1 && NAME =~ "*dwrq4*"}]
set pw_rq [get_cells -hier -filter {REF_NAME == DSP48E1 && NAME =~ "*pwrq4*"}]
set mac_modules [get_cells -hier -filter {REF_NAME =~ "m11a_pw_mac_cell*"}]
emit $fh "PW_MAC_MODULE_COUNT=[llength $mac_modules] PW_MAC_DSP_DESCENDANTS=[llength $mac_dsp] PW_MAC_CARRY4=[llength $mac_carry] PW_MAC_LUT=[llength $mac_lut]"
emit $fh "DSP_PARTITION dw_mac=[llength $dw_mac] pw_mac=[llength $mac_dsp] dw_rq4=[llength $dw_rq] pw_rq4=[llength $pw_rq] total=[llength $dsp]"
emit $fh "DW_DSP_NAMES=[join [lsort -dictionary [get_property NAME $dw_mac]] {; }]"
emit $fh "PW_DSP_NAMES=[join [lsort -dictionary [get_property NAME $mac_dsp]] {; }]"
emit $fh "DWRQ_DSP_NAMES=[join [lsort -dictionary [get_property NAME $dw_rq]] {; }]"
emit $fh "PWRQ_DSP_NAMES=[join [lsort -dictionary [get_property NAME $pw_rq]] {; }]"
emit $fh "ALL_DSP_NAMES=[join [lsort -dictionary [get_property NAME $dsp]] {; }]"
close $fh
close_design
exit
