set checkpoint [file normalize [lindex $argv 0]]
set out [file normalize [lindex $argv 1]]
cd $out
set_param general.maxThreads 8

proc safe_property {object property} {
    if {[catch {get_property $property $object} value]} { return "n/a" }
    return [string map [list "\t" " " "\r" " " "\n" " "] $value]
}

proc try_report {name command} {
    global out optionalErrors
    if {[catch {uplevel #0 $command} message]} {
        puts $optionalErrors "$name: $message"
        puts "OPTIONAL_REPORT_ERROR $name: $message"
    } else {
        puts "OPTIONAL_REPORT_OK $name"
    }
}

proc write_hierarchy_inventory {path} {
    set fh [open $path w]
    puts $fh "NAME\tREF_NAME\tORIG_REF_NAME\tPARENT\tLOC\tBEL\tASYNC_REG\tSHREG_EXTRACT"
    foreach cell [lsort -dictionary [get_cells -hier -quiet]] {
        set row {}
        foreach property {NAME REF_NAME ORIG_REF_NAME PARENT LOC BEL ASYNC_REG SHREG_EXTRACT} {
            lappend row [safe_property $cell $property]
        }
        puts $fh [join $row "\t"]
    }
    close $fh
}

proc write_clock_properties {directory prefix} {
    set clockCount 0
    foreach clock [get_clocks -quiet *] {
        set clockName [safe_property $clock NAME]
        if {$clockName eq "" || $clockName eq "n/a"} { set clockName "clock_$clockCount" }
        report_property -file [file join $directory "${prefix}_${clockName}.txt"] $clock
        incr clockCount
    }
    if {$clockCount == 0} { error "No clocks available for property inventory" }
}

proc write_reset_inventory {path} {
    set fh [open $path w]
    puts $fh "kind\tcell\tpin\tnet\tREF_NAME\tORIG_REF_NAME\tLOC\tBEL\tASYNC_REG\tSHREG_EXTRACT"
    set resetPins [get_pins -hier -quiet -filter {REF_PIN_NAME =~ CLR || REF_PIN_NAME =~ PRE}]
    puts $fh "# async_control_pin_count\t[llength $resetPins]"
    foreach pin [lsort -dictionary $resetPins] {
        set cell [get_cells -quiet -of_objects $pin]
        set net [get_nets -quiet -of_objects $pin]
        set row [list async_control [safe_property $cell NAME] [safe_property $pin NAME] \
            [safe_property $net NAME] [safe_property $cell REF_NAME] \
            [safe_property $cell ORIG_REF_NAME] [safe_property $cell LOC] \
            [safe_property $cell BEL] [safe_property $cell ASYNC_REG] \
            [safe_property $cell SHREG_EXTRACT]]
        puts $fh [join $row "\t"]
    }
    set asyncCells [get_cells -hier -quiet -filter {ASYNC_REG == TRUE}]
    puts $fh "# ASYNC_REG_true_cell_count\t[llength $asyncCells]"
    foreach cell [lsort -dictionary $asyncCells] {
        set row [list ASYNC_REG [safe_property $cell NAME] "" "" \
            [safe_property $cell REF_NAME] [safe_property $cell ORIG_REF_NAME] \
            [safe_property $cell LOC] [safe_property $cell BEL] \
            [safe_property $cell ASYNC_REG] [safe_property $cell SHREG_EXTRACT]]
        puts $fh [join $row "\t"]
    }
    close $fh
}

proc write_timing_path_inventory {path pathObjects} {
    set fh [open $path w]
    puts $fh "path_count\t[llength $pathObjects]"
    puts $fh "PATH_TYPE\tSLACK\tSTARTPOINT_PIN\tENDPOINT_PIN\tSTARTPOINT_CLOCK\tENDPOINT_CLOCK"
    foreach timingPath $pathObjects {
        set row {}
        foreach property {PATH_TYPE SLACK STARTPOINT_PIN ENDPOINT_PIN STARTPOINT_CLOCK ENDPOINT_CLOCK} {
            lappend row [safe_property $timingPath $property]
        }
        puts $fh [join $row "\t"]
    }
    close $fh
}

proc report_endpoint_group {name cellPatterns} {
    global out
    set cells {}
    foreach pattern $cellPatterns {
        set found [get_cells -hier -quiet -filter "NAME =~ $pattern"]
        set cells [concat $cells $found]
    }
    set cells [lsort -unique $cells]
    set targetPins {}
    if {[llength $cells] > 0} {
        set targetPins [get_pins -quiet -of_objects $cells -filter {REF_PIN_NAME == D}]
    }
    set fh [open [file join $out "${name}_selection.txt"] w]
    puts $fh "cell_count\t[llength $cells]"
    puts $fh "endpoint_D_pin_count\t[llength $targetPins]"
    puts $fh "# No matching D pins means no stage timing claim can be made from this group."
    close $fh
    if {[llength $targetPins] > 0} {
        report_timing -to $targetPins -delay_type max -max_paths 20 \
            -path_type full_clock_expanded -input_pins -nets \
            -file [file join $out "${name}_setup_paths.txt"]
    }
}

open_checkpoint $checkpoint
set primary [get_clocks -quiet physical_clk]
set core [get_clocks -quiet -of_objects [get_pins -quiet u_clocking/u_mmcm/CLKOUT0]]
if {[llength $primary] != 1 || abs([get_property PERIOD $primary]-8.0)>0.0001 ||
    [get_property IS_GENERATED $primary]} {
    error "Expected exactly one 8 ns physical_clk primary"
}
set primaryCount 0
foreach clk [get_clocks -quiet *] {
    if {![get_property IS_GENERATED $clk]} {incr primaryCount}
}
if {$primaryCount != 1} {
    error "Expected only physical_clk as a primary clock; found $primaryCount"
}
if {[llength $core] != 1 || ![get_property IS_GENERATED $core] ||
    [get_property MASTER_CLOCK $core] ne "physical_clk" ||
    abs([get_property PERIOD $core]-8.0)>0.0001} {
    error "Expected CLKOUT0 generated 1:1 from physical_clk at 8 ns"
}
if {[llength [get_cells -hier -filter {REF_NAME =~ MMCME*}]] != 1 ||
    [llength [get_cells -hier -filter {REF_NAME =~ BUFG*}]] != 2} {
    error "Expected one MMCM and separate feedback/core BUFGs"
}
# Apply only the corrected 0.050 ns jitter after opening the immutable DCP.
set_input_jitter [get_clocks physical_clk] 0.050
if {abs([get_property INPUT_JITTER [get_clocks physical_clk]]-0.050)>0.0001} {
    error "Corrected physical_clk INPUT_JITTER overlay did not take effect"
}
report_clocks -file $out/clocks_input_checkpoint.txt
write_clock_properties $out clock_properties_input_checkpoint

# Keep the selected physical candidate fixed: one default opt and Explore
# placement, physical optimization, and routing from the accepted M DCP.
opt_design
place_design -directive Explore
phys_opt_design -directive Explore
route_design -directive Explore

# Preserve the routed implementation before any optional diagnostic/report
# command. Report failures are recorded without losing the routed checkpoint.
write_checkpoint -force $out/routed.dcp
set optionalErrors [open $out/optional_report_errors.txt w]
set routeStatus [safe_property [current_design] ROUTE_STATUS]
set routeStatusFile [open $out/route_status_properties.txt w]
puts $routeStatusFile "ROUTE_STATUS\t$routeStatus"
puts $routeStatusFile "ROUTING_ERRORS\t[safe_property [current_design] ROUTING_ERRORS]"
puts $routeStatusFile "IS_ROUTE_FIXED\t[safe_property [current_design] IS_ROUTE_FIXED]"
close $routeStatusFile

try_report route_status [list report_route_status -file $out/route_status.txt]
try_report clocks_post_route [list report_clocks -file $out/clocks_post_route.txt]
try_report clock_interaction [list report_clock_interaction -file $out/clock_interaction_post_route.txt]
try_report clock_properties [list write_clock_properties $out clock_properties_post_route]
try_report mmcm_properties [list report_property -file $out/mmcm_properties_post_route.txt [get_cells -hier -quiet -filter {REF_NAME =~ MMCME*}]]
try_report utilization_flat [list report_utilization -file $out/utilization_post_route.txt]
try_report utilization_hier [list report_utilization -hierarchical -file $out/utilization_post_route_hier.txt]
try_report timing_summary [list report_timing_summary -delay_type min_max -report_unconstrained -file $out/timing_post_route.txt]
try_report check_timing [list check_timing -verbose -file $out/check_timing_post_route.txt]
try_report exceptions [list report_exceptions -file $out/exceptions_post_route.txt]
try_report setup_paths [list report_timing -delay_type max -max_paths 20 -path_type full_clock_expanded -input_pins -nets -file $out/setup_paths.txt]
try_report hold_paths [list report_timing -delay_type min -max_paths 10 -path_type full_clock_expanded -input_pins -nets -file $out/hold_paths.txt]
set registers [all_registers]
try_report internal_setup_paths [list report_timing -from $registers -to $registers -delay_type max -max_paths 20 -path_type full_clock_expanded -input_pins -nets -file $out/internal_setup_paths.txt]
try_report drc [list report_drc -file $out/drc.txt]
# Vectorless estimated power only; no activity trace or operational energy claim.
try_report power_vectorless [list report_power -file $out/power_vectorless.txt]

if {[catch {write_hierarchy_inventory $out/hierarchy_cells_post_route.tsv} message]} {
    puts $optionalErrors "hierarchy_inventory: $message"
    puts "OPTIONAL_REPORT_ERROR hierarchy_inventory: $message"
}
if {[catch {write_reset_inventory $out/async_reset_endpoints_post_route.tsv} message]} {
    puts $optionalErrors "async_reset_inventory: $message"
    puts "OPTIONAL_REPORT_ERROR async_reset_inventory: $message"
}

# Export M-specific max/min timing path sources and destinations for external
# reset and MMCM LOCKED to all mapped asynchronous control pins. These checks
# are recorded as evidence and are not treated as synchronous closure.
set asyncControlPins [get_pins -hier -quiet -filter {REF_PIN_NAME =~ CLR || REF_PIN_NAME =~ PRE}]
set resetSourceGroups [list \
    [list external_rst_n [get_ports -quiet rst_n]] \
    [list mmcm_locked [get_pins -quiet -hier u_clocking/u_mmcm/LOCKED]]]
foreach sourceGroup $resetSourceGroups {
    set sourceName [lindex $sourceGroup 0]
    set sourceObjects [lindex $sourceGroup 1]
    foreach delayType {max min} {
        set pathFile [file join $out "async_reset_${sourceName}_${delayType}_paths.tsv"]
        if {[catch {
            set paths [get_timing_paths -quiet -from $sourceObjects -to $asyncControlPins \
                -delay_type $delayType -max_paths 10000]
            write_timing_path_inventory $pathFile $paths
        } message]} {
            puts $optionalErrors "async_reset_${sourceName}_${delayType}_paths: $message"
            puts "OPTIONAL_REPORT_ERROR async_reset_${sourceName}_${delayType}_paths: $message"
        }
    }
}

foreach diagnostic [list \
    [list lane_partial_product [list *mac_sum* *product*]] \
    [list rq_round_clamp [list *rq_round* *rq_clamp*]] \
    [list state [list *state_reg*]] \
    [list halo_address [list *spatial_word* *read_a* *read_b*]]] {
    set name [lindex $diagnostic 0]
    set patterns [lindex $diagnostic 1]
    if {[catch {report_endpoint_group $name $patterns} message]} {
        puts $optionalErrors "${name}_endpoint_group: $message"
        puts "OPTIONAL_REPORT_ERROR ${name}_endpoint_group: $message"
    }
}

close $optionalErrors
exit
