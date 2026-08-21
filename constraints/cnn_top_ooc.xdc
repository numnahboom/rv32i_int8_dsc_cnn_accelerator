# Out-of-context implementation constraint for the CNN core.
#
# This is deliberately limited to the core clock.  Board/package pin placement
# and IO electrical constraints belong in a board-level wrapper constraint file.
#
# Do not guard get_ports with a Tcl `if`: in a pre-synthesis read_xdc flow the
# top port can be resolved only when synth_design elaborates the top.  The
# implementation Tcl keeps this XDC before synthesis, then verifies (and only
# if needed recreates) the queryable clock after top elaboration.
create_clock -name clk -period 10.000 [get_ports clk]
