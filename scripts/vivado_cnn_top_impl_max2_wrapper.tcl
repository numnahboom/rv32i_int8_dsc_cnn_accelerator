# Temporary launcher for a controlled full-top implementation run.
# The implementation flow requests four threads by default; intercept that
# single parameter so this run is reproducibly limited to two threads.
rename set_param ::vivado_original_set_param
proc set_param {name value} {
    if {$name eq "general.maxThreads"} {
        set value 2
    }
    return [::vivado_original_set_param $name $value]
}

source [file join [file dirname [file normalize [info script]]] "vivado_cnn_top_impl.tcl"]
