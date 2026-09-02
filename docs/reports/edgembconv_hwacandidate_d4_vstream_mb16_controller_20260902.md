# D4 vstream mb16_down independent controller

Date: 2026-09-02

## Boundary

This candidate is independent of C0, the legacy mb16 controller, and the
legacy composite datapath.  It uses the mechanically extracted 112-lane PW
island, the 16-DSP elastic PW/RQ pool, and the standalone DW16 tile through a
legacy-shaped source adapter.

## RTL and validation

- Top: `edgembconv_hwacandidate_d4_vstream_mb16_controller`
- Datapath: `edgembconv_hwacandidate_d4_vstream_datapath`
- PW island: `edgembconv_hwacandidate_d4_vstream_pw112`
- Testbench: `tb_edgembconv_hwacandidate_d4_vstream_mb16_controller`
- Script: `run_edgembconv_hwacandidate_d4_vstream_mb16_controller_sim.sh`
- Source and expected data: the frozen `mb16_down` block-shell vector set.

The standalone extracted PW smoke check passed for distinct pixel values, and
the existing 16-DSP dual-mode pool and standalone DW16 vector tests pass.
The integrated real-vector run completes all 8,192 outputs and all 512 DW
tiles under deterministic randomized source/output backpressure, but is a
NEGATIVE_RESULT: byte-exact comparison reports 7,456 mismatches.  Measured
controller cycles are 129,723, above the 25,000-cycle gate.  No result is
claimed as accuracy-equivalent.

The current adapter intentionally bubbles response-to-next-request because the
legacy controller exposes only one scratch read-pending bit.  The integrated
controller also uses an issue/commit RQ split so the elastic pool does not
replay a single RQ context.

## Remaining risks

The PW/RQ component-level arithmetic is independently validated, but the
full-block mismatch is not resolved.  The standalone DW16 primitive has the
16 channel DSP bank; the current adapter does not yet provide the desired
two explicit scheduler DSP cells.  No synthesis or cycle claim is made.

