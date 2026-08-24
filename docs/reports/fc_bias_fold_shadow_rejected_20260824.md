# FC bias-fold shadow-table experiment (2026-08-24)

## Candidate

The current routed Explore timing paths are dominated by
`u_layer_runner/u_fc_unit/class_idx_reg -> bias_mem/acc_mem -> carry chain ->
three DSP48E1 product_reg` endpoints.  A task-local candidate added a
start-local distributed `acc_bias_mem[0:9]` table, populated with
`acc_mem[i] + bias_mem[i]`, and used that table in the existing product issue
cycle.  This removes the 32-bit bias-add carry chain without changing the FC
issue cadence or external handshake.

## Functional gate

Verilator `tb_fc_unit` passed 2 cases / 20 checks, and the Verilator integrated
gap/fullnet runs retained the known fullnet single mismatch at `0004d410`
(`expected=2`, `actual=0`).  However, XSim integrated tests exposed new
candidate-specific unknown outputs:

- SRAM gap/FC: `0000c010 expected=0 actual=x`
- tail: `00036010 expected=-2 actual=x`
- fullnet: known location `0004d410 expected=2 actual=x`

The candidate therefore failed the functional gate before implementation and
was reverted.  No routed OOC run was started.

## Decision

Do not retain this shadow-table approach.  The direct FC class-indexed LUTRAM
path remains the dominant family.  The next safe direction should preserve
the existing valid initialization/configuration semantics while reducing
fanout or arithmetic depth, rather than creating a start-time derived table.
