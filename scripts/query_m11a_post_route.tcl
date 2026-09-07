# Read-only post-route hierarchy query for the M1.1-A diagnostic report.
set dcp [file normalize [file join [file dirname [info script]] .. build reports m11a_runtime_dw_pw_core_ooc_8ns m11a_runtime_dw_pw_core_ooc_8ns_post_route.dcp]]
open_checkpoint $dcp
set dsp [get_cells -hier -filter {REF_NAME == DSP48E1}]
puts "DSP_COUNT=[llength $dsp]"
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
puts "DSP_BY_HIER dw16=$dw pw64=$pw other=$other"
set mac_cells [get_cells -hier -filter {REF_NAME =~ "m11a_pw_mac_cell*"}]
set mac_dsp [get_cells -hier -filter {REF_NAME == DSP48E1 && NAME =~ "*GEN_PW64_MAC*"}]
set mac_carry [get_cells -hier -filter {REF_NAME == CARRY4 && NAME =~ "*GEN_PW64_MAC*"}]
set mac_lut [get_cells -hier -filter {IS_PRIMITIVE && NAME =~ "*GEN_PW64_MAC*" && REF_NAME =~ "LUT*"}]
puts "PW_MAC_MODULE_COUNT=[llength $mac_cells] PW_MAC_DSP_DESCENDANTS=[llength $mac_dsp] PW_MAC_CARRY4=[llength $mac_carry] PW_MAC_LUT=[llength $mac_lut]"
set dw_dsp [get_cells -hier -filter {REF_NAME == DSP48E1 && NAME =~ "*dw16*"}]
set pw_dsp [get_cells -hier -filter {REF_NAME == DSP48E1 && NAME =~ "*pw64*"}]
puts "DW_DSP_NAMES=[join [lsort -dictionary [get_property NAME $dw_dsp]] {; }]"
puts "PW_DSP_NAMES=[join [lsort -dictionary [get_property NAME $pw_dsp]] {; }]"
puts "ALL_DSP_NAMES=[join [lsort -dictionary [get_property NAME $dsp]] {; }]"
close_design
exit
