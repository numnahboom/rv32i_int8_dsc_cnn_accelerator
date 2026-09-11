# Vivado 2025.2 command-support probe for the retiming/remap experiment.
# This script is read-only: it does not read RTL or create a design.
set script_dir [file dirname [file normalize [info script]]]
set project_root [file normalize [file join $script_dir ".."]]
set out_dir [file join $project_root "build" "reports" "vivado_cnn_top_retime_remap_help_20260909"]
file mkdir $out_dir
set result_file [file join $out_dir "command_help.txt"]
set fh [open $result_file "w"]
puts $fh "vivado_version=[version -short]"
puts $fh "probe=read-only command help; no design, RTL, or implementation state"
foreach command_name {synth_design opt_design phys_opt_design place_design route_design} {
    puts $fh "=== help -verbose $command_name ==="
    flush $fh
    set help_text ""
    if {[catch {set help_text [help -verbose $command_name]} error_text]} {
        puts $fh "ERROR: $error_text"
    } else {
        puts $fh $help_text
    }
}
foreach command_name {synth_design opt_design phys_opt_design} {
    puts $fh "=== direct $command_name -help ==="
    flush $fh
    set help_text ""
    if {[catch {set help_text [uplevel #0 [list $command_name -help]]} error_text]} {
        puts $fh "ERROR: $error_text"
    } else {
        puts $fh $help_text
    }
}
close $fh
puts "RETIME_REMAP_HELP_PROBE $result_file"
exit 0
