# Frozen D4 portable inputs

`d4_p_portable.tar.gz` contains the 14 accepted D4 test vector sets, frozen
INT8 model/deployment manifest, and small FPGA acceptance/source/report
artifacts. `d4_p_portable.tar.json` records the archive hash. It contains no
PDK, commercial tool files, large waveform, or routed checkpoint.

From a clean checkout (Python >=3.6, standard library only):

```sh
python3 scripts/d4_portable_bundle.py restore
```

Restoration verifies every member, refuses path traversal and changed existing
files, and installs only under `build/`. Model/vector identities and the FPGA
baseline remain fixed. Historic acceptance records refer to additional large
artifacts retained in the original workspace; this bundle is not a replacement
for the complete physical implementation archive.

ASIC experiments must identify their technology, library corner, constraints,
memory implementation, and verification scope independently. FPGA numbers
must never be relabeled as ASIC results.

`d4_asic_stage2_evidence_20261020.tar.gz` contains accepted real-SRAM full-network
functional logs, isolated mapped RQ reports and source/view hashes. Its SHA256 is
`cbd95374bbfaffe9890d11ff4a936ebd678362f9350f4c54a86a881b926ff720`.
It contains no PDK, generated macro model/library/LEF/GDS, or mapped netlist.
It is a functional/macro integration stage, not complete ASIC PPA or energy.
Extract it into an isolated review directory to preserve existing build files:

```sh
mkdir -p build/asic_evidence_review
tar -xzf artifacts/d4_asic_stage2_evidence_20261020.tar.gz -C build/asic_evidence_review
```

`d4_asic_asymmetric_evidence_20261020.tar.gz` preserves the accepted A1 full
functional comparison. `d4_asic_macro_area_scope_20261020.json` separates compiler
datasheet area from actual LEF/Liberty placement footprint.

`d4_asic_A3_functional_evidence_20261020.tar.gz` contains 60 public evidence files
for the selected 19-macro A3 candidate. Recheck its returned source/log identities,
84 exact inferences, unit/protocol markers, A1 metric agreement and macro-area
arithmetic with `python3 scripts/accept_d4_asic_A3.py` after generating matching
A3 RTL from the frozen portable inputs. Root acceptance JSON files explicitly
keep full-core PPA, physical timing and energy as separate unaccepted gates.

`d4_asic_fullcore_synth_evidence_20261020.tar.gz` retains A2/A3 complete-core
numerical reports, A3 report-only checkpoint recovery and private mapping hashes.
`python3 scripts/accept_d4_asic_synth.py` verifies the returned reports against
both locally regenerated RTL candidates. That original A2 archive has no saved
mapped checkpoint; a later same-area rebuild is retained separately on-server.

`d4_asic_formal_evidence_20261020.tar.gz` retains the successful A3 RTL-to-mapped
proof with its original setup/interpretation warnings and macro-boundary report.
`python3 scripts/accept_d4_asic_formal.py` binds it to the accepted mapping and
RTL, checking all 252 functional output and 652 memory input-pin compare points.
Memory contents are covered by the separate actual-model functional evidence.
The retained raw log also contains an SVF file-info parser error. The root
acceptance explicitly records this qualification; a new parser-compatible proof
is incomplete. This archive must not be described as unqualified proof closure.

`d4_asic_reset_probe_evidence_20261020.tar.gz` preserves the small actual-cell
synchronous-reset contrast: default mapping retains X at reset, while explicit
reset inference passes 1100 checks from uninitialized DUT state. Recheck both
the negative and positive logs with `python3 scripts/accept_d4_asic_reset_probe.py`.
It establishes the unit synthesis policy only; no full-network gate, physical
timing, area gain or power result is inferred from it.

`d4_asic_gate_specify_evidence_20261020.tar.gz` retains four original A3
synchronous-reset mapped-gate logs, with two epochs each, and their source/run
identities. `python3 scripts/accept_d4_asic_gate.py` rechecks all eight exact
inferences and the public archive allowlist. Default library propagation arcs,
disabled timing checks and no SDF are explicit boundaries.

`d4_asic_pg_construction_evidence_20261020.tar.gz` retains the shared PG helper's
pre-CTS placed-checkpoint component test. `python3 scripts/accept_d4_asic_pg.py`
checks 19 macros, 38 PG terminals, zero special DRC and zero VDD/VSS connectivity
errors/warnings. It does not accept the new mapping's full routed core or power.
