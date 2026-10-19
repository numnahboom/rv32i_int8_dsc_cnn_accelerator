#!/usr/bin/env python3
"""Generate explicitly identified ASIC evaluation sources from frozen P.

This is an arithmetic/RTL portability stage, not an ASIC memory implementation.
The full-network evaluation still uses initialized behavioral memories. The
FPGA source and frozen input files are never overwritten.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
P_SHA = "d438bc8855d2999307bed61b044c3b4fb716e5f17e53afbe5ba830bec323083e"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def logic_roms(text, sample):
    """Replace simulation-only initialization by constant, synthesizable ROMs.

    This fixed-weight baseline intentionally maps parameter ROMs into standard
    cells. It does not pretend to be a compiled mask-ROM or a programmable NPU.
    """
    start = text.index("    initial begin\n")
    end = text.index("    reg [1:0] kind", start)
    text = text[:start] + text[end:]
    functions = []
    for array, filename, width, address_width in (
            ("weights", "weights.mem", 512, 12),
            ("biases", "bias.mem", 512, 8),
            ("multipliers", "multiplier.mem", 512, 8),
            ("shifts", "shift.mem", 512, 8),
            ("descriptors", "descriptors.mem", 32, 11),
            ("residual_lut", "residual_lut9.mem", 9, 12)):
        words = [int(s, 16) for s in (sample / filename).read_text().split()]
        if len(words) > 1 << address_width or any(v >= 1 << width for v in words):
            raise RuntimeError("ROM shape mismatch: " + array)
        names = [array] if array != "residual_lut" else [array + str(i) for i in range(4)]
        for name in names:
            pattern = r"reg(?: signed)? \[\d+:0\] " + name + r" \[0:[^\]]+\];"
            text, count = re.subn(pattern, "", text)
            if count != 1:
                raise RuntimeError("Missing unique ROM declaration: " + name)
        name = "asic_" + array
        functions += ["    function automatic [{}:0] {}(input [{}:0] address);".format(width-1, name, address_width-1),
                      "        case(address)"]
        for address, word in enumerate(words):
            functions.append("            {}'d{}: {}={}'h{:0{}x};".format(address_width, address, name, width, word, (width+3)//4))
        functions += ["            default: {}={}'d0;".format(name, width), "        endcase", "    endfunction"]
    text = text.replace("weights[weight_addr]", "asic_weights(weight_addr[11:0])")
    for array in ("biases", "multipliers", "shifts"):
        text = text.replace(array + "[qaddr]", "asic_" + array + "(qaddr)")
    text, count = re.subn(r"residual_lut[0-3]\[([a-zA-Z0-9_]+)\]", r"asic_residual_lut(\1)", text)
    if count != 8:
        raise RuntimeError("Expected eight residual ROM read ports")
    # Aliases avoid slicing a function-call expression, unsupported by some tools.
    aliases = []
    for index in range(21):
        old = "descriptors[{op_index,5'b0}+" + str(index) + "]"
        if text.count(old) != 1:
            raise RuntimeError("Unexpected descriptor read: " + old)
        text = text.replace(old, "asic_desc_" + str(index))
        aliases.append("    wire [31:0] asic_desc_{}=asic_descriptors({{op_index,5'b0}}+11'd{});".format(index, index))
    insertion = text.index("    reg [1:0] kind")
    # Preserve the original testbench's descriptor inspection without restoring
    # simulation-only initialization or synthesizing an extra array.
    inspection = ["`ifndef SYNTHESIS", "    wire [31:0] descriptors [0:OP_COUNT*32-1];",
                  "    genvar inspect_descriptor;",
                  "    generate for(inspect_descriptor=0;inspect_descriptor<OP_COUNT*32;inspect_descriptor=inspect_descriptor+1) begin: descriptor_inspection",
                  "        assign descriptors[inspect_descriptor]=asic_descriptors(inspect_descriptor);",
                  "    end endgenerate", "`endif"]
    text = text[:insertion] + "\n".join(functions + aliases + inspection) + "\n" + text[insertion:]
    return text


def prepare(style, feature_style, parameter_style, out):
    source = ROOT / "rtl/cnn/d4_fullnet_top.sv"
    data = source.read_bytes()
    if sha(data) != P_SHA:
        raise RuntimeError("Frozen P source mismatch; select a new baseline explicitly")
    text = data.decode("utf-8")
    text, attributes = re.subn(r"\(\*.*?\*\)", "", text, flags=re.DOTALL)
    if text.count('/residual_lut.mem') != 4:
        raise RuntimeError("Unexpected residual initialization structure")
    text = text.replace('/residual_lut.mem', '/residual_lut9.mem')
    if feature_style == "banked":
        text, count = re.subn(r"reg \[127:0\] features \[0:6143\];", "", text)
        if count != 1:
            raise RuntimeError("Expected exactly one feature array")
        text = text.replace("reg [127:0] fm_a, fm_b;", "wire [127:0] fm_a, fm_b;")
        start = text.index("    always @(posedge clk) begin\n        if(port_a_en)")
        end = text.index("    function automatic [7:0] saturate8", start)
        old = text[start:end]
        if old.count("features[") != 4 or old.count("always @(posedge clk)") != 2:
            raise RuntimeError("Unexpected feature memory boundary")
        text = text[:start] + """    d4_feature_banks feature_banks(
        .clk(clk),
        .a_en(port_a_en),.a_we(write_en_a),.a_re(fm_read_a),
        .a_addr(port_a_addr),.a_wdata(write_data),.a_rdata(fm_a),
        .b_en(port_b_en),.b_we(write_en_b),.b_re(fm_read_b),
        .b_addr(port_b_addr),.b_wdata(result_vector),.b_rdata(fm_b)
    );
""" + text[end:]
    tables = []
    for sample in sorted((ROOT / "build/d4_fullnet_vectors").glob("sample_*")):
        original = sample / "residual_lut.mem"
        values = [int(s, 16) for s in original.read_text().split()]
        signed = [v if v < (1 << 31) else v - (1 << 32) for v in values]
        if not all(-256 <= v <= 255 for v in signed):
            raise RuntimeError("Residual table cannot be represented exactly in signed9")
        narrow = ("".join("{:03x}\n".format(v & 511) for v in signed)).encode("ascii")
        target = sample / "residual_lut9.mem"
        if target.exists() and target.read_bytes() != narrow:
            raise RuntimeError("Refusing to overwrite changed narrow LUT")
        target.write_bytes(narrow)
        tables.append({"sample": sample.name, "entries": len(values),
                       "source_sha256": sha(original.read_bytes()), "signed9_sha256": sha(narrow)})
    if len(tables) != 14:
        raise RuntimeError("Expected the complete accepted 14 input sets")
    if parameter_style == "logic-rom":
        text = logic_roms(text, ROOT / "build/d4_fullnet_vectors/sample_0")
    if style == "native":
        text, count = re.subn(r"d4_rq_partial_multiplier_lane(?=\s+\w+\s*\()",
                              "d4_rq_native_multiplier_lane", text)
        if count != 1:
            raise RuntimeError("Expected exactly one generated lane instantiation")
    out.mkdir(parents=True, exist_ok=True)
    generated = out / "d4_fullnet_eval.sv"
    generated.write_bytes(text.encode("utf-8"))
    manifest = {"baseline_sha256": P_SHA, "rq_style": style, "feature_style": feature_style,
                "parameter_style": parameter_style,
                "fpga_attributes_removed": attributes, "generated_sha256": sha(generated.read_bytes()),
                "residual_tables": tables,
                "initialization": "behavioral" if parameter_style == "behavioral" else "fixed constant parameter ROM logic",
                "network_precision_and_valid_latency": "unchanged"}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("D4_ASIC_PREPARE_PASS style={} signed9_tables={} attributes_removed={}".format(style, len(tables), attributes))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rq-style", choices=("partial", "native"), default="partial")
    parser.add_argument("--feature-style", choices=("array", "banked"), default="array")
    parser.add_argument("--parameter-style", choices=("behavioral", "logic-rom"), default="behavioral")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    tag = args.rq_style if args.feature_style == "array" else args.rq_style + "_banked"
    if args.parameter_style == "logic-rom":
        tag += "_logic_rom"
    prepare(args.rq_style, args.feature_style, args.parameter_style, args.out or ROOT / "build/asic_eval" / tag)
