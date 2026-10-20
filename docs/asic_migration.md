# D4 ASIC migration (2026-10-19)

The new target is a convincing, reproducible network/hardware ASIC result.
The FPGA P prototype stays frozen at commit `bfb60e5`; its timing, BRAM, DSP,
and Vivado power numbers are not ASIC evidence. D4 arithmetic, weights and
11,645,440 semantic MAC remain the starting functional contract.

## Server and source

- SSH alias `lab-ljw`: `ljw@172.25.71.67`, host `ic03`.
- Checkout: `/home/ljw/projects/rv32i_int8_dsc_cnn_accelerator`.
- ASIC branch: `codex/d4-asic-smic180`.
- Frozen input restore: `python3 scripts/d4_portable_bundle.py restore`.
- Installed: Xcelium 20.03, Design Compiler O-2018.06-SP5, Innovus 19.1.
- Available locally: SMIC SCC018UG HD RVT standard-cell corners/LEF and
  SMIC RHEL4/RHEL5 SRAM, dual-port SRAM, register-file and ROM compilers.
  Installation discovery does not imply a working license or usable macro.
- Process libraries and derived proprietary views stay on the server and are
  never added to the public repository. Public artifacts contain scripts,
  source/parameter identities and our design's measured summary evidence.

## Gates and design decisions

1. Reproduce the frozen full-network exact regression with the server simulator;
   check tool execution and a small actual-library mapped synthesis.
2. Establish explicit SRAM/ROM contracts: capacity, ports, synchronous latency,
   read/write collision semantics, reset, initialization and loading. ASIC
   storage cannot inherit FPGA BRAM initialization implicitly. Check compiler
   validity, corners and timing models before full-chip synthesis.
3. Compare the inherited four-partial-product RQ lane with an exact native
   signed32 multiplier at equal valid latency/throughput and equal constraints.
   Select using actual mapped area/timing and representative activity; no
   inference-level power claim from an isolated lane.
4. Integrate the selected arithmetic and memory adapters, rerun complete-network
   intermediate values, final accumulators, MAC ledger and protocol/reset tests.
5. Map and physically implement the complete design with an honest memory and
   I/O budget. Report process/PVT, clocks, constraints, macro area, cell area,
   timing violations, utilization and activity coverage. Synthesis estimates
   stay labeled as such; no timing signoff or complete-chip GOPS/W from blackboxes.
6. Use a small controlled architecture/network comparison to substantiate the
   design choice. Preserve accuracy, precision and operation-count differences
   explicitly if later experiments change the network.

Initial ASIC evaluation keeps 125 MHz as a reference, not as a technology-neutral
acceptance target. The design must earn its frequency/area/energy tradeoff under
the actual 180 nm library; FPGA resource percentages no longer apply.

## Accepted stage 1

FPGA source and portable inputs pushed; server clone and all 427 bundle member
checks passed. Use `dc_shell-xg-t -64bit`, with the server's existing license
environment; the plain `dc_shell` entry point reports DCSH-1 on this install.
Serialize short SSH/SCP connections and allow cleanup between them; rapid new
connections may be closed before authentication. A long-running tool job can
coexist with a read-only SSH connection. Use SCP files, not terminal-pasted archives.

The laboratory server is shared. New native jobs check load and available
memory first and run at `nice +10`; Innovus uses at most four workers. Heavy
simulation/implementation jobs and report-only native geometry queries are
scheduled serially. SDF simulation starts with a short startup check, followed
by the two selected inputs one at a time. No full-dataset simulation is implied
by the current validation scope, and other users' processes are untouched.

Both partial-product and native signed32 RQ implementations passed 84 complete
network inferences each (14 inputs x 3 stall modes x 2 epochs), with 24,336
intermediate words, 10 raw FC values and 11,645,440 semantic MAC per inference.
All sample/mode/epoch metrics match. The 128-bit core's mode0 latency is 255,740
cycles; this boundary differs from the FPGA 32-bit input wrapper (258,814).
Separate arithmetic verification passed 17,498 comparisons and 21 resets.

Equal-library isolated RQ synthesis, SMIC HD RVT TT 1.8 V/25 C, 8 ns period,
0.2 ns uncertainty, 0.5 ns max I/O delay and 0.01 pF output load:

| RQ implementation | Mapped cell area (um2) | Cells |
| --- | ---: | ---: |
| inherited four partial products | 76,184.728399 | 2,877 |
| native full signed32 multiplier | 61,937.253872 | 2,715 |

Native reduces isolated lane area by 18.7012%. Both meet synthesis setup with
very small slack; this is neither routed closure nor a complete-chip area or
energy claim. Area was independently parsed from `report_area`: the initial
Tcl design-area attribute query was unavailable and its incomplete JSON is not
accepted. `scripts/collect_d4_asic.py` checks the original reports and all 84+84
functional markers/metrics before writing the stage-1 acceptance record.

The three single-port activation-bank candidate also passed all 84 inferences,
with unknown initial memory and Q invalidated on writes, and no bank conflicts.
This establishes functional compatibility with a write-output-undefined SRAM.

The real compiler generated 2048x128/M8 SRAM views (default cell name misleadingly
remains `RASP2048X16M16`; actual width/depth in the views must be verified). One
macro has datasheet area 1,504,450.238 um2; three have 4.513350714 mm2. Its TT/SS
read access values are 2.597/4.160 ns. This is macro-only evidence, not full-chip
area/timing. A separate `-instance` naming attempt was rejected; no nonexistent
named macro is used. SRAM DB compilation passed for typical/worst/best corners;
NLPM/internal-power metadata warnings remain, so no macro power claim is made.
The compiler returns 1 after successful generation and 0 for some invalid
options: acceptance must inspect generated view contents, not just exit status.

The real macro uses active-low CEN, active-high WE and active-high OE. A first
adapter with inverted WE failed at the first layer; it was corrected using the
actual model. The fixed-parameter ROM transformation separately passed six
full-network inferences with behavioral banks. Real-macro regression then passed
all 84 inferences, mapped-gate arithmetic passed 17,498 comparisons, and native
SS 8 ns synthesis passed with area 62,890.597879 um2. Root verified returned
source/report/log identities. Full-core synthesis and physical implementation
remain pending. See [ASIC development evidence](reports/d4_asic_development_20261020.md).

The A0 full-core synthesis baseline deliberately implements the fixed D4 parameter
tables as standard-cell ROM logic, with all area included. This removes every
`initial`/`$readmemh` from the synthesized core; it does not claim mask-ROM density
or omit weight storage. Only activation memories use the three compiled SRAMs.
The core has a 128-bit input boundary; host and pads are separate deployment
costs, and a complete routed result must include its clock tree.

A1's descriptor-shaped [2048,1024,2048] activation banks pass the complete exact
regression, reducing actual activation LEF/Liberty area by 14.2723%. A2 uses
eight real 4096x64 weight ROMs; selected A3 adds eight independent 4096x16 ROMs
for exact signed9 residual lookup. Both pass full-network and reset/protocol
checks. A3's 19 memories total 7.670230033 mm2 of placement footprint; full-core
mapped and routed costs are still separate acceptance gates. Source, program,
area scopes, tool limitations and current results are maintained in the
[development report](reports/d4_asic_development_20261020.md).

Current checkpoints are summarized at the beginning of that report. The
synchronous-reset A3 mapping now passes eight mapped-gate inferences under
default library propagation, without SDF/timing checks. A shared PG construction
component passes; the current A3 error-free formal proof also passes all 13,758
compare points at identical memory boundaries. Full corrected routing remains
a separate gate. The [activity and energy contract](asic_power_contract.md)
specifies the measurement boundary before any ASIC power claim.
The [physical prototype acceptance](asic_physical_acceptance.md) preserves
unfiltered DRC results and defines the evidence required to distinguish macro
OBS width diagnoses from actual routing violations.
