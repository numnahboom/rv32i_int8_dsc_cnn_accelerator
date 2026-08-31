#!/usr/bin/env python3
"""Reproduce the DS persistent-bank traffic ledger.

The numbers are derived from the C10 layer shapes and the 32-bit transfer
contract, not from a reduced-MAC model.  The measured columns are the three
PW configurations exercised by tb_ds_persistent_feed_contract.
"""
from pathlib import Path
import csv

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build" / "reports"
OUT.mkdir(parents=True, exist_ok=True)

# P is the PW input/output spatial count.  dw_source_pixels is the preceding
# feature-map count used when the same bank contract is applied to DW.
layers = [
    dict(layer="DS1", p=1024, cin=16, cout=32, dw_source_pixels=1024,
         dual_source=4608+16384, dual_param=9216+16384,
         measured_load=9563, measured_jobs=187, measured_jobs_n=3),
    dict(layer="DS2", p=256, cin=32, cout=64, dw_source_pixels=256,
         dual_source=2304+16384, dual_param=4608+16384,
         measured_load="-", measured_jobs="-", measured_jobs_n=0),
    dict(layer="DS3", p=256, cin=64, cout=64, dw_source_pixels=256,
         dual_source=4608+32768, dual_param=9216+32768,
         measured_load=9564, measured_jobs=400, measured_jobs_n=2),
    dict(layer="DS4", p=64, cin=64, cout=128, dw_source_pixels=64,
         dual_source=1152+16384, dual_param=2304+16384,
         measured_load="-", measured_jobs="-", measured_jobs_n=0),
    dict(layer="DS5", p=64, cin=128, cout=128, dw_source_pixels=64,
         dual_source=2304+32768, dual_param=4608+32768,
         measured_load="-", measured_jobs="-", measured_jobs_n=0),
    dict(layer="DS6", p=16, cin=128, cout=256, dw_source_pixels=64,
         dual_source=576+16384, dual_param=1152+16384,
         measured_load=18029, measured_jobs=795, measured_jobs_n=2),
]

for x in layers:
    # A PW source window is loaded once per spatial feature map.  The DW
    # source column is the dense source map; PW consumes the local DW output
    # handoff and therefore adds no external source transfer.
    x["packed_source"] = x["dw_source_pixels"] * x["cin"] // 4
    x["packed_param"] = (x["cin"] * x["cout"] + 3) // 4 + (9*x["cin"] + 3) // 4
    x["pw_source"] = x["p"] * x["cin"] // 4
    x["pw_param"] = x["cin"] * x["cout"] // 4
    x["pw_windows"] = (x["p"] + 7) // 8
    x["pw_tokens_per_all_cout"] = x["p"] * x["cin"] * ((x["cout"] + 7)//8) // 8

csv_path = OUT / "ds_persistent_feed_contract_ledger.csv"
fields = ["layer", "p", "cin", "cout", "dual_source", "dual_param",
          "packed_source", "packed_param", "pw_source", "pw_param",
          "pw_windows", "pw_tokens_per_all_cout", "measured_load",
          "measured_jobs", "measured_jobs_n"]
with csv_path.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows({k: x[k] for k in fields} for x in layers)

ds_dual_source = sum(x["dual_source"] for x in layers)
ds_dual_param = sum(x["dual_param"] for x in layers)
ds_packed_source = sum(x["packed_source"] for x in layers)
ds_packed_param = sum(x["packed_param"] for x in layers)
full_dual_source, full_dual_param = 154560, 190848
full_packed_source = ds_packed_source + 6912 + 1024  # unchanged Stem + FC
full_packed_param = ds_packed_param + 27648 + 1024

md_path = OUT / "ds_persistent_feed_contract_ledger.md"
with md_path.open("w") as f:
    f.write("# DS persistent packed-bank feed ledger (2026-08-31)\n\n")
    f.write("Reproduce with `python scripts/model_ds_persistent_feed_contract.py`. ")
    f.write("The companion RTL test is `scripts/run_ds_persistent_feed_contract_sim.sh`.\n\n")
    f.write("## Measured RTL probes\n\n")
    f.write("The measured cycles include the request/response loader and the tested jobs; they are not full-layer runtime claims.\n\n")
    f.write("| probe | cfg/load cycles | job cycles | external source words | external param words | local source reads | local param row reads | reused windows |\n")
    f.write("|---|---:|---:|---:|---:|---:|---:|---:|\n")
    f.write("| DS1 PW, 3 jobs (two share pixel window) | 9563 | 187 | 4096 | 128 | 112 | 48 | 1 |\n")
    f.write("| DS3 PW, 2 jobs (same pixel window) | 9564 | 400 | 4096 | 1024 | 256 | 128 | 1 |\n")
    f.write("| DS6 PW, 2 jobs (same pixel window) | 18029 | 795 | 512 | 8192 | 512 | 256 | 1 |\n\n")
    f.write("Every accepted token was checked against the nonzero source/weight address reference. ")
    f.write("The TB applies independent source/parameter request bubbles and token backpressure; final aggregate was 432 tokens, ")
    f.write("880 local source reads (window gathers plus token-row reads), 432 local parameter reads, and 3 window reuses.\n\n")
    f.write("## C10 traffic projection\n\n")
    f.write("| layer | shape (P,Cin,Cout) | dual32 source | packed external source | dual32 parameter | packed parameter | PW source once | PW parameter once |\n")
    f.write("|---|---|---:|---:|---:|---:|---:|---:|\n")
    for x in layers:
        f.write(f"| {x['layer']} | ({x['p']},{x['cin']},{x['cout']}) | {x['dual_source']} | {x['packed_source']} | {x['dual_param']} | {x['packed_param']} | {x['pw_source']} | {x['pw_param']} |\n")
    f.write(f"| **DS subtotal** | | **{ds_dual_source}** | **{ds_packed_source}** | **{ds_dual_param}** | **{ds_packed_param}** | | |\n\n")
    f.write(f"The retained full-network dual32 reference is **{full_dual_source} source + {full_dual_param} parameter words**. ")
    f.write(f"Keeping Stem/FC traffic unchanged and replacing only the six DS feed paths projects **{full_packed_source} source + {full_packed_param} parameter words**. ")
    f.write(f"That is {100*(1-full_packed_source/full_dual_source):.1f}% fewer source transfers and {100*(1-full_packed_param/full_dual_param):.1f}% fewer parameter transfers. ")
    f.write("This is traffic projection, not a full-top cycle or timing result.\n\n")
    f.write("## Storage and port contract\n\n")
    f.write("The default source bank is 32,768 x 32 bits (1,048,576 bits, ceiling 29 RAMB36); the packed parameter bank is 4,096 x 64 bits (262,144 bits, 8 RAMB36). ")
    f.write("The combined worst-case projection is therefore 37 RAMB36, 26.4% of the 140-RAMB36 full-top budget and below the 98-RAMB36 promotion ceiling. ")
    f.write("In a production integration these banks replace the corresponding repeated source/parameter staging, rather than being added alongside it; the prototype itself does not alter cnn_top.\n\n")
    f.write("The external source and parameter ports are single outstanding request/response channels with explicit ready and one-cycle response capture. ")
    f.write("Loading is completed before commit, and committed banks are read-only during token service, so no source or parameter read/write collision exists. ")
    f.write("The local eight-pixel window is written during gather and read only after the gather fence. A future dual-port implementation can preserve this phase contract.\n\n")
    f.write("## Scope and promotion boundary\n\n")
    f.write("`mode=0` has a complete PW K-token contract. `mode=1` exposes and checks the real DW source/parameter word accounting but deliberately does not claim a 3x3 DW token schedule. ")
    f.write("The PASS therefore proves persistent packed PW parameter storage, source-window reuse, nonzero address fidelity, tails/masks in the token ABI, epochs/sessions, and backpressure—not DS integration, fullnet logits, or XC7Z020 post-route closure.\n")

print(md_path)
print(csv_path)
