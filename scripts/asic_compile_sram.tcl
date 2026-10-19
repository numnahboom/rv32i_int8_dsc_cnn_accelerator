# Compile locally generated macro views, never publish them.
set root build/asic_macros/act_2048x128
set cell RASP2048X16M16
if {[info exists env(D4_SRAM_ROOT)]} {set root $env(D4_SRAM_ROOT)}
if {[info exists env(D4_SRAM_CELL)]} {set cell $env(D4_SRAM_CELL)}
foreach corner {typical worst best} {
    set filename $root/${cell}_${corner}.lib
    set f [open $filename r]
    set text [read $f]
    close $f
    if {![regexp {library\s*\(\s*"?([^\s\)" ]+)"?\s*\)} $text -> name]} {error "Missing library name"}
    read_lib $filename
    write_lib $name -format db -output $root/${cell}_${corner}.db
}
puts "D4_ASIC_SRAM_LIBRARIES_COMPILED"
quit
