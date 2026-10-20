# Command discovery only; no design or PPA claim.
foreach command {restoreDesign sroute setSrouteMode editDelete editSelect verify_drc setOptMode optDesign reportPower read_activity_file set_power_analysis_mode} {
    puts "D4_HELP_BEGIN=$command"
    catch {help $command}
    puts "D4_HELP_END=$command"
}
exit
