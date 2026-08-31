set dcp [lindex $argv 0]
set outdir [file normalize [lindex $argv 1]]
file mkdir $outdir
open_checkpoint $dcp

proc q {s} { return [string map {"\n" " " "," ";"} $s] }
set csv [open [file join $outdir family_summary.csv] w]
puts $csv "family,start_pattern,end_pattern,start_count,end_count,path_count,slack_sum,worst_slack,worst_start,worst_end,worst_datapath_delay,worst_logic_delay,worst_route_delay,worst_logic_levels,worst_carry4,worst_dsp,limitation"

set families {
  {A_stride_to_tiled_input {*stride_reg*/C} {*tiled_input_index_next*/CEC}}
  {B_tile_h_to_store_addr {*tile_h_start_reg*/C} {*tiled_store_addr_current*/D}}
  {C_store_idx_to_outbuf_enbwren {*store_idx_reg*/C} {*ENBWREN}}
  {D_stride_to_aux_cfg {*stride_reg*/C} {*aux_cfg_index*/CE}}
}

foreach spec $families {
  set name [lindex $spec 0]
  set spattern [lindex $spec 1]
  set epattern [lindex $spec 2]
  set from [get_pins -hierarchical $spattern]
  set to [get_pins -hierarchical $epattern]
  set rpt [file join $outdir "${name}_max200_full.rpt"]
  set worst [file join $outdir "${name}_worst_full.rpt"]
  set nfrom [llength $from]
  set nto [llength $to]
  set paths {}
  if {$nfrom > 0 && $nto > 0} {
    catch {set paths [get_timing_paths -delay_type max -from $from -to $to -max_paths 200 -nworst 200 -sort_by slack]} emsg
  }
  set n [llength $paths]
  set sum 0.0
  set worstSlack 1e30
  set wp ""; set we ""; set wdd "NA"; set wld "NA"; set wrd "NA"; set wll "NA"; set wc "NA"; set wd "NA"
  if {$n > 0} {
    report_timing -delay_type max -from $from -to $to -max_paths 200 -nworst 200 -sort_by slack -path_type full -input_pins -nets -file $rpt
    report_timing -delay_type max -from $from -to $to -max_paths 1 -nworst 1 -sort_by slack -path_type full -input_pins -nets -file $worst
  }
  foreach p $paths {
    set s [get_property SLACK $p]
    set sum [expr {$sum + $s}]
    if {$s < $worstSlack} {
      set worstSlack $s
      set wp [get_property STARTPOINT_PIN $p]
      set we [get_property ENDPOINT_PIN $p]
      foreach {prop var} {DATAPATH_DELAY wdd LOGIC_DELAY wld ROUTE_DELAY wrd LOGIC_LEVELS wll} { catch {set $var [get_property $prop $p]} }
      # Cell and primitive counts are recorded from the corresponding full report below.
    }
  }
  if {$n == 0} { set worstSlack "NA"; set limitation "no matching timing paths" } else { set limitation "counts are constrained by -max_paths 200; primitive/net details are in worst_full.rpt" }
  puts $csv [join [list $name $spattern $epattern $nfrom $nto $n $sum $worstSlack [q $wp] [q $we] $wdd $wld $wrd $wll $wc $wd [q $limitation]] ,]
  set detail [open [file join $outdir "${name}_worst_properties.txt"] w]
  puts $detail "family=$name"
  puts $detail "from_pattern=$spattern matched=$nfrom"
  puts $detail "to_pattern=$epattern matched=$nto"
  puts $detail "path_count=$n slack_sum=$sum worst_slack=$worstSlack"
  puts $detail "startpoint=$wp"
  puts $detail "endpoint=$we"
  puts $detail "datapath_delay=$wdd logic_delay=$wld route_delay=$wrd logic_levels=$wll"
  close $detail
}
close $csv

report_timing -delay_type max -max_paths 200 -nworst 200 -sort_by slack -path_type full -input_pins -nets -file [file join $outdir all_max200_full.rpt]
set pba [file join $outdir all_max_pba50_full.rpt]
set pbaMsg [catch {report_timing -delay_type max -max_paths 50 -nworst 50 -sort_by slack -path_type full -input_pins -nets -pba_mode exhaustive -file $pba} pbaErr]
set f [open [file join $outdir audit_status.txt] w]
puts $f "dcp=$dcp"
puts $f "pba_catch_code=$pbaMsg"
puts $f "pba_message=$pbaErr"
close $f
report_timing_summary -delay_type max -file [file join $outdir timing_summary_max.rpt]
close_design
puts "AUDIT_DONE outdir=$outdir"
