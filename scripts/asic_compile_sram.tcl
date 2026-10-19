# Compile locally generated macro views, never publish them.
set root build/asic_macros/act_2048x128
foreach corner {typical worst best} {
    set filename $root/RASP2048X16M16_${corner}.lib
    set f [open $filename r]
    set text [read $f]
    close $f
    if {![regexp {library\s*\(\s*"?([^\s\)" ]+)"?\s*\)} $text -> name]} {error "Missing library name"}
    read_lib $filename
    write_lib $name -format db -output $root/RASP2048X16M16_${corner}.db
}
puts "D4_ASIC_SRAM_LIBRARIES_COMPILED"
quit
