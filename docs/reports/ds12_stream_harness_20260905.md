# DS1 -> DS2 streaming pre-acceptance harness

This harness is an independent reference and transaction checker. It does not
change `cnn_top`, any retained layer, or an existing candidate datapath.

## Reproduction

From WSL (the script uses Windows `python.exe` when that is the Python install
that has NumPy):

```bash
cd /mnt/d/Stuff/Project
bash scripts/ds12_stream_run.sh
```

The reference defaults to the current C0 INT8 export
`build/c0_hwqa_export/edgedscnet_c10_int8_smoke.npz`. It emits the DS1 input and
output, DS2 input and output, real DS1/DS2 DW/PW INT8 streams, packed config
transactions, sink words, and `ds12_stream_contract.json` under
`build/ds12_stream_harness/`.

## Evidence

- The Python reference checks the centered C0 source image, evaluates the real
  quantized stem -> DS1 -> DS2 path, and cross-checks the exported full-network
  logits/argmax.
- Packed parameter traffic is exactly 308 DS1 words and 872 DS2 words. INT8
  values are packed little-endian four-per-word; all quantization arrays remain
  32-bit words. Every packed array is round-tripped byte/word-for-word.
- Every DS1/DS2 sink byte is represented by a valid 32-bit word (`byte_mask=F`)
  with exact addresses. The ledger records semantic DW/PW MACs as well as the
  current C10 stream counts (DW beats, PW tokens, output words).
- Eight-pixel contexts carry one of four tags. Owner alternates between two
  banks and epoch advances only on a completed context; the epoch is
  inference-global, so DS2 continues after the DS1 fence. Read responses are
  recorded one cycle after each request.
- The Verilator TB checks the generated memory/transaction files and prints
  `REFERENCE_PASS`; it also prints `DUT_DEFERRED` because no candidate module is
  instantiated. This is deliberately not an architecture PASS. Defining
  `DS12_STREAM_DUT` selects the port-only, non-functional stub and waits for
  all 12,288 sink words; it times out rather than falsely passing.
  The runner exposes the same mode with `DS12_STREAM_DUT=1`; a real candidate
  source can be appended using `DS12_STREAM_DUT_FILE=...` and selected with
  `DS12_STREAM_DUT_MODULE=...`.

The package is a pre-DUT acceptance boundary. It does not establish RTL
equivalence, timing, resources, power, board behavior, or full-network closure.
