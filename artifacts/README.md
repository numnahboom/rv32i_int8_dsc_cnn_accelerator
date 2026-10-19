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
