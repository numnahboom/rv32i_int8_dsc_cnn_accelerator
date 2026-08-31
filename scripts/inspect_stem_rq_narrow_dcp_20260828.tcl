# Inspect the DSP packing selected for the narrow signed requant product.
set dcp [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
open_checkpoint $dcp
set fh [open $out w]
foreach c [get_cells -hier -filter {REF_NAME == DSP48E1}] {
    puts $fh "CELL [get_property NAME $c] AREG=[get_property AREG $c] BREG=[get_property BREG $c] MREG=[get_property MREG $c] PREG=[get_property PREG $c] USE_MULT=[get_property USE_MULT $c]"
}
close $fh
exit
