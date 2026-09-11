# Full-top M1.1-A DS12 implementation gate: 8 ns core clock.
# Board/package IO constraints are intentionally outside this core-level run.
create_clock -name clk -period 8.000 [get_ports clk]
