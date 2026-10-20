# ASIC activity and energy evidence contract

This contract defines the next measurement, not a measured power result. D4
remains 11,645,440 semantic MAC / 23,290,880 ops per complete inference, at
unchanged INT8/INT32 precision. Compare A2 and A3 with the same constraints,
input cases, measurement window and reporting boundary.

## Hardware and timing boundary

Use the exact accepted routed 128-bit core, including inserted clock cells,
standard cells, three activation SRAMs and every instantiated parameter ROM.
Record netlist, checkpoint, SPEF, SDF, libraries, memory programs and simulator
model hashes. Pads, host, preprocessing and per-channel FC scaling are outside
this bare-core boundary. FPGA on-chip total power has a different boundary.

The selected physical experiment targets a 10 ns clock. Drive activity with
that actual period, rather than inheriting the RTL testbench's 8 ns clock.
Acceptance of this frequency requires the corresponding complete setup/hold
checks. For routed activity, use the appropriate extracted SDF and audit native
annotation errors and coverage; default library propagation alone is a weaker
activity estimate and must retain that label.

## Activity capture

Retain the full port-level exact scoreboard: intermediate words, raw FC values,
MAC ledger, handshake stability and completion. Exercise at least sample0 and
synthetic checkerboard separately; neither is a dataset power average. Record
the observed continuous start interval rather than inferring it from latency.

Use the same complete capture window for operation count, duration and power.
A window containing reset, two complete inferences and completion overhead
counts exactly two networks. If a steady interval is reported separately, it
needs its own matching activity window and power result. Do not combine its
shorter duration with power from a longer capture.

Xcelium 20.03 supports native `dumpsaif` and `dumptcf`. A small API smoke test
with a 100 MHz clock and 100 counter increments reports a 1,001 ns window,
200 clock transitions and the expected counter-bit transition counts. This
checks duration units and tool plumbing only; it is not D4 activity or power.
Innovus 19.14 accepts TCF activity through `read_activity_file`. Keep the
unfiltered default transition counts; do not suppress glitches to improve the
reported result. Keep large/private activity files on the server.

## Power model and coverage

Report the actual analysis view, voltage, temperature, RC corner and tool
version. Verify units from the loaded libraries: standard-cell leakage is in
uW and generated-macro leakage in nW. The compiler's NLPM/internal-power
metadata warning remains unresolved; demonstrate the behavior of the loaded
macro power tables before accepting a complete total. A zero or omitted macro
contribution needs diagnosis, not interpretation as free storage.

Publish switching, internal and leakage contributions for standard cells,
clock cells and each macro group, and their sum. Audit activity matches against
the routed design inventory, including clock nets and SRAM/ROM controls,
addresses and data. Report unmatched objects, defaults, propagated activity
and unknown-state fractions separately. Overlapping annotations cannot be
added to inflate coverage. Tool defaults remain visible.

The examined SRAM's two internal-power conditions are `CEN` and `!CEN`; the
weight ROM similarly uses `CSB` and `!CSB`. Audit enable-conditioned clock
events against the simulation, rather than assuming pin annotation alone
establishes conditional coverage. The SRAM table does not separately condition
on write enable, so its read/write energy distinction is a model limitation;
do not invent a separate write-energy table or silently claim data-dependent
memory energy fidelity.

## Calculations

For N completed networks in the same measured window of T seconds and total
core power P watts:

- throughput = N * 23,290,880 / T / 1e9 GOPS;
- energy per inference = P * T / N joules;
- energy efficiency = throughput / P GOPS/W.

Total power includes internal, switching and leakage. Also report complete
start-to-raw-FC latency and measured start interval in cycles and seconds.
Results are tool estimates under the stated activity/PVT/model coverage, not
silicon measurements, a worst-case power bound or foundry signoff.
