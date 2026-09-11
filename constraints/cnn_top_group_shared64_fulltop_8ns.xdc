# Production group-published shared64 full-top implementation: 8 ns core clock.
# Board/package IO constraints are intentionally outside this core-level run.
create_clock -name clk -period 8.000 [get_ports clk]
