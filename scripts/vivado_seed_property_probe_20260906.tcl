set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build seed_property_probe_20260906]]
file mkdir $out
set project_dir [file normalize [file join $out project]]
create_project seed_property_probe $project_dir -part xc7z020clg400-1 -force
set impl_run [lindex [get_runs -quiet impl_*] 0]
if {$impl_run eq ""} { error "project did not create a default implementation run" }
set f [open [file join $out run_properties.txt] w]
puts $f [report_property [get_runs $impl_run]]
close $f
set f [open [file join $out run_property_names.txt] w]
foreach p [list_property [get_runs $impl_run]] { puts $f $p }
close $f
set f [open [file join $out seed_property_filter.txt] w]
foreach p [list_property [get_runs $impl_run]] {
    if {[string match -nocase *seed* $p] || [string match -nocase *place* $p] || [string match -nocase *route* $p]} {
        puts $f "$p=[get_property $p [get_runs $impl_run]]"
    }
}
close $f
close_project
exit
