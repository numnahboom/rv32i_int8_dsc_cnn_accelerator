# Group-published shared64 DS sweep (2026-08-31)

This is an isolated producer/consumer vehicle for the partial-K output-
stationary direction.  It is not connected to `cnn_top` or
`cnn_layer_runner`.  A 4x8 DW macro writes one of two scratch banks; a narrow
descriptor is published only after the second 4-channel half of a row/group.
The PW side consumes the published row in K-group order.  `first_k` is asserted
only on the first K token of each row/Cout tile and `last_k` only on its final
K token.  Intermediate groups remain in the accumulator and are not sent to
requantization.

## Reproduction and results

From PowerShell:

```text
wsl.exe bash -lc "cd /mnt/d/Stuff/Project && bash scripts/run_ds_group_published_shared64_sweep_sim.sh"
```

The Verilator 5.020 sweep completed with `PASS`, exact signed output checks,
and the following per-layer ledger.  `rq_writes` is the accepted requant
output-beat count; `rq_groups` is the number of complete output groups.  The
`overlap_cycles` column counts cycles in which a DW beat and a PW token were
accepted in the same cycle.

| layer | P | Cin | Cout | cycles | DW writes | desc | PW tokens | RQ writes | preload | overlap | first/last | rq groups | intermediate RQ | MACs | writes checked |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1024 | 16 | 32 | 14,946 | 4,096 | 256 | 8,192 | 8,192 | 64 | 2,268 | 512/512 | 512 | 0 | 524,288 | 32,768 |
| 1 | 256 | 32 | 64 | 12,506 | 2,048 | 128 | 8,192 | 4,096 | 256 | 1,354 | 256/256 | 256 | 0 | 524,288 | 16,384 |
| 2 | 256 | 64 | 64 | 20,947 | 4,096 | 256 | 16,384 | 4,096 | 512 | 3,196 | 256/256 | 256 | 0 | 1,048,576 | 16,384 |
| 3 | 64 | 64 | 128 | 10,524 | 1,024 | 64 | 8,192 | 2,048 | 1,024 | 746 | 128/128 | 128 | 0 | 524,288 | 8,192 |
| 4 | 64 | 128 | 128 | 18,970 | 2,048 | 128 | 16,384 | 2,048 | 2,048 | 1,623 | 128/128 | 128 | 0 | 1,048,576 | 8,192 |
| 5 | 16 | 128 | 256 | 9,660 | 512 | 32 | 8,192 | 1,024 | 4,096 | 284 | 64/64 | 64 | 0 | 524,288 | 4,096 |
| **sum** |  |  |  | **87,553** | **13,824** | **864** | **65,536** | **21,504** | **8,000** | **9,471** | **1,344/1,344** | **1,344** | **0** | **4,194,304** | **86,016** |

The machine-readable source is
`build/reports/ds_group_published_shared64_sweep_metrics.csv`.  It additionally
records `dw_stalls`, `output_stalls`, `audit_tokens`, and `ops` (8,388,608 for
the sweep).  All six layers report `audit_tokens == pw_tokens`, exact
`first_k == last_k == rows*cout_tiles`, zero `intermediate_rq`, and all valid
output bytes match the independent reference.

## OOC post-route attempt

The first attempt used
`scripts/vivado_ds_group_published_shared64_sweep_ooc_20260831.tcl` and the
fixed output directory
`build/reports/vivado_ds_group_published_shared64_sweep_ooc_20260831/`.  Its
log ended at `Start Technology Mapping` after synthesis cross-boundary
optimization; there were no timing, utilization, route, or power reports and
no live Vivado process remained.  It did not emit a Vivado Tcl diagnostic, so
that log alone is an incomplete/crashed run rather than a timing result.

The corrected fresh run uses a unique directory and removes the unused
`systolic_pe.v` input:

```text
D:\Software\vivado2025.2\2025.2\Vivado\bin\vivado.bat -mode batch -nolog -nojournal -notrace -log build/vivado_ds_group_published_shared64_sweep_ooc_20260831_rerun1.log -source scripts/vivado_ds_group_published_shared64_sweep_ooc_20260831_rerun1.tcl
```

It was started only after confirming no live Vivado process.  The rerun exited
cleanly from Vivado with the concrete failure:

```text
The application has run out of memory
while executing
"synth_design -top ds_group_published_shared64_sweep ..."
```

The log is
`build/vivado_ds_group_published_shared64_sweep_ooc_20260831_rerun1.log`.
Consequently this slice has no post-route WNS/TNS/WHS/THS, resource, power, or
route-status numbers to report.  It must not be presented as OOC timing
closure.  The failure is an implementation-environment/resource-screen
blocker (about 15.6 GB visible RAM with about 1.5 GB free at launch), not a
functional simulation failure.

