# FC configuration-phase bias folding experiment (rejected, 2026-08-24)

## Candidate and intent

`rtl/cnn/fc_unit_new.v` was temporarily changed to fold each configured bias
into the FC accumulator.  `CFG_BIAS` applied a signed delta
`new_bias-old_bias` during configuration, and the run-time product used the
folded accumulator directly, removing the compute-time `acc+bias` adder from
the FC class-index to DSP/product-register cone.  The normal configuration
ordering is input, weight, bias, multiplier, and shift; bias storage was kept
to preserve repeated-write behavior.  No precision, network operation, or
interface protocol was intentionally changed.

## Verification commands and results

The candidate was tested with:

```text
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && ./scripts/run_sim.sh tb_cnn_top_sram_gap_fc_datapath'
wsl.exe bash -lc 'cd /mnt/d/Stuff/Project && ./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath'
pwsh -NoProfile -File scripts/run_cnn_xsim.ps1 -Tests tb_cnn_top_sram_gap_fc_datapath
```

The targeted Verilator test passed (`10/10`).  The targeted XSim run retained
the known baseline signature `MISMATCH case=0 i=4 addr=0000c010 expected=0
actual=x`; this was not used as the candidate-specific failure because the
same signature is present in the parent-isolated baseline evidence.

The fullnet Verilator run failed the functional gate:

```text
MISMATCH case=0 i=4 addr=0004d410 expected=2 actual=0
PERF ... hw_cycles=995220 checks=10 errors=1
```

To rule out accumulator-width overflow as the cause, two further local
variants used 33-bit and 64-bit folded accumulators, respectively, with
explicit signed product operands.  Both reproduced the same fullnet class-4
mismatch.  The RTL was restored to its pre-experiment contents after each
failure; no candidate source change remains.

## Implementation gate

No Vivado routed OOC run was started because the candidate failed the required
functional gate.  Consequently there are no candidate WNS/TNS/WHS/THS,
route, utilization, or power results.  The active Explore reference remains
WNS `-6.997 ns`, TNS `-26365.537 ns`, WHS `+0.061 ns`, with zero unrouted nets.

## Disposition

Rejected and reverted.  The fullnet mismatch demonstrates that this local
configuration-folding strategy does not yet preserve the integrated FC
configuration/data-flow semantics, despite the directed case passing.  No
task RTL file was committed for the candidate; this report is the sole
task-owned artifact.
