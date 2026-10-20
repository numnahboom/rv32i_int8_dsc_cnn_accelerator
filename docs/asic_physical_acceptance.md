# ASIC physical prototype acceptance (2026-10-20)

The earlier plan required zero records from native `verify_drc -check_only all`.
The first corrected A3 route fails that gate: 190 records, together with failed
hold timing. The all-scope result remains negative and must never be relabeled
as zero. This revision defines a separate, qualified engineering-prototype
gate before applying it to the repaired result.

The installed Innovus 19.14 documentation explains that `all` checks routing
and other shapes, including cell pin/OBS and routing blockages. A LEF obstacle
is an abstraction for routing, not a reconstruction of the macro's fabricated
conductors. A remaining OBS width diagnosis therefore needs classification;
it cannot be silently discarded or automatically called a false positive.

## Required evidence from one final checkpoint

1. Preserve the exact tool version, executed scripts/commands, constraints,
   netlist, checkpoint, extraction and all technology/macro-view identities.
   Generate every final check after the last repair; do not combine zero-error
   reports from different checkpoints.
2. Pass setup and hold in the fixed analysis views: SS/TT setup, FF hold,
   10 ns clock and unchanged OCV, uncertainty and I/O budgets. Audit clock
   coverage, unconstrained paths and exceptions with native checks. Report the
   actual minimum margins; a small positive margin is model dependent.
3. Pass all-net and explicit VDD/VSS connectivity with zero errors/warnings.
   Inventory all instantiated PG and body-bias terminals against the actual
   library definitions. An unassigned body pin can be absent from a named-net
   connectivity check; VNW/VPW warnings need evidence-based resolution.
4. Preserve complete unfiltered `all` DRC records. Native `regular` and
   `special` scopes must have zero violations, with their documented coverage
   of route-to-pin/OBS interactions recorded. No routing rule is disabled.
5. If cell-shape diagnoses remain, match every `all` record to its counterpart
   in the `cell` set by rule, layer, macro instance and location/object.
   Demonstrate that each measured width belongs to the OBS itself and involves
   no actual wire, pin conflict or unexplained object. Equal counts or the
   phrase `Blockage of Cell` alone are insufficient. Keep private geometry
   audits and source hashes; do not publish proprietary LEF/GDS payloads.
   Inventory additional cell-scope records separately. In the current failed
   checkpoint these include 9,448 same-macro Pin/Blockage spacing diagnoses;
   the 190 width matches are a subset, not a bijection of the whole reports.
   Each remaining category also needs an actual source-geometry explanation.
6. Prove the final physical netlist equivalent to the accepted mapping, at the
   same technology-memory boundaries. Link it to the accepted full-network
   real-model tests. Exact final-netlist SDF simulation and power activity use
   the same accepted implementation identity.

Root may accept this qualified LEF/Liberty routed prototype when all conditions
hold, explicitly retaining the nonzero all-scope diagnostic count and its
classification. If any record remains unexplained or a real routing violation
persists, the gate stays negative. No OBS deletion, geometry shrink, blanket
MINWIDTH/MAXWIDTH suppression or constraint relaxation is used to obtain zero.

This gate supports physical feasibility and model-based timing/energy studies.
It does not establish macro GDS manufacturing-rule closure, full-rule zero DRC,
LVS, IR/EM, or tapeout readiness. These limits also remain in power reports.
After root explicitly releases the final checkpoint, apply the separate
[activity and energy contract](asic_power_contract.md); preparation alone is
not authorization to measure a rejected route.

Documentation basis: installed Innovus 19.14 Text Command Reference,
`/opt/cadence/innovus/191/doc/innovusTCR/verify_drc.html`, `-check_only` table.
Root chose this boundary after independent read-only specialist advice; the
actual object classification and final pass remain evidence-dependent.
