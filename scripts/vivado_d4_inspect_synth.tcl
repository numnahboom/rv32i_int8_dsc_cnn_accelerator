set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
set_param general.maxThreads 8
open_checkpoint $checkpoint
report_timing -delay_type max -from [all_registers] -to [all_registers] \
    -max_paths 12 -file $out/internal_setup_paths.txt
set fh [open $out/ram_cells.txt w]
foreach c [lsort [get_cells -hier -filter {REF_NAME =~ RAMB*}]] {
    puts $fh "[get_property REF_NAME $c] $c"
}
close $fh
exit
