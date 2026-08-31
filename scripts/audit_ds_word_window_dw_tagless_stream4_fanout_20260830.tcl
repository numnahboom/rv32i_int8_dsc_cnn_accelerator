set root [file normalize [file join [file dirname [info script]] ..]]
set out [file normalize [file join $root build reports vivado_ds_word_window_dw_tagless_stream4_ooc_20260830]]
open_checkpoint [file join $out ds_word_window_dw_tagless_stream4_ooc_post_route.dcp]
report_high_fanout_nets -timing -load_types -max_nets 50 \
    -file [file join $out high_fanout_post_route.txt]
exit
