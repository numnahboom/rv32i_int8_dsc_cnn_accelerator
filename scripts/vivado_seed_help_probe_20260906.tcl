set dcp [file normalize [file join [file dirname [info script]] .. build reports vivado_ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_20260906 ds12_stream_ds2_pw_consumer_ooc_8ns_ledger_banked_post_synth.dcp]]
read_checkpoint $dcp
foreach p {place.seed place.randomSeed place.random_seed place.rngSeed route.seed route.randomSeed route.random_seed route.rngSeed} {
    set rc [catch {get_param $p} v]
    if {$rc == 0} { puts "GET $p=$v" } else { puts "GET $p ERROR=$v" }
    set rc [catch {set_param $p 2} v]
    if {$rc == 0} { puts "SET $p=$v" } else { puts "SET $p ERROR=$v" }
}
exit
