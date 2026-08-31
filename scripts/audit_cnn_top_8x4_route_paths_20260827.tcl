set dcp [lindex $argv 0]
set outdir [lindex $argv 1]
file mkdir $outdir
open_checkpoint $dcp
set rpt [file join $outdir timing_max_200.rpt]
report_timing -delay_type max -max_paths 200 -nworst 200 -sort_by slack -path_type full -input_pins -nets -file $rpt
report_timing -delay_type max -max_paths 200 -nworst 1 -sort_by slack -path_type summary -file [file join $outdir timing_max_200_unique.rpt]
set rptp [file join $outdir timing_max_pba_50.rpt]
catch {report_timing -delay_type max -max_paths 50 -nworst 50 -sort_by slack -path_type full -input_pins -nets -pba_mode exhaustive -file $rptp} pba_msg
set csv [open [file join $outdir timing_path_families.csv] w]
puts $csv "index,slack,datapath_delay,startpoint,endpoint,start_hier,end_hier,logic_delay,route_delay,fanout"
set paths [get_timing_paths -delay_type max -max_paths 200 -nworst 200]
set i 0
foreach p $paths {
  incr i
  set sp [get_property STARTPOINT_PIN $p]
  set ep [get_property ENDPOINT_PIN $p]
  set slack [get_property SLACK $p]
  set dd [get_property DATAPATH_DELAY $p]
  set ld "NA"
  set rd "NA"
  set fo "NA"
  catch {set ld [get_property LOGIC_DELAY $p]}
  catch {set rd [get_property ROUTE_DELAY $p]}
  catch {set fo [get_property ENDPOINT_CLOCK_LATENCY $p]}
  set sph [join [lrange [split $sp /] 0 end-2] /]
  set eph [join [lrange [split $ep /] 0 end-2] /]
  puts $csv [join [list $i $slack $dd $sp $ep $sph $eph $ld $rd $fo] ,]
}
close $csv
report_timing_summary -delay_type max -file [file join $outdir timing_summary_max.rpt]
report_route_status -file [file join $outdir route_status.rpt]
close_design
puts "AUDIT_DONE paths=$i pba=$pba_msg"
