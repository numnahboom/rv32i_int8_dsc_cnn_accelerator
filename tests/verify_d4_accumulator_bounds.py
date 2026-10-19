"""Conservative bounds for every live accumulator over all signed INT8 inputs."""
import argparse
import hashlib
import json
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('vectors', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    data = args.vectors

    def words(name):
        return [int(x, 16) for x in (data / name).read_text().split()]

    def signed(x, width):
        x &= (1 << width) - 1
        return x - (1 << width) if x & (1 << (width - 1)) else x

    descs, weights, biases = [words(x) for x in ('descriptors.mem', 'weights.mem', 'bias.mem')]
    rows = []
    semantic_macs = 0
    for op in range(41):
        d = descs[op*32:(op+1)*32]
        if d[0] not in (0, 3):
            continue
        cin, cout, kernel, dw = d[6], d[7], d[10], bool(d[12])
        semantic_macs += d[8]*d[9]*cout*kernel*kernel*(1 if dw else cin)
        steps = kernel*kernel*(1 if dw else (cin+3)//4)
        lower, upper, lanes = 0, 0, []
        for group in range((cout+15)//16):
            for lane in range(min(16, cout-16*group)):
                bias = signed(biases[d[15]+group] >> (lane*32), 32)
                lo = hi = bias
                for k in range(steps):
                    packed = weights[d[14]+group*steps+k] >> (lane*32)
                    # Padding entries are zero; even the full four entries are a
                    # valid conservative bound independent of spatial halo input.
                    for j in range(4):
                        w = signed(packed >> (8*j), 8)
                        lo += min(-128*w, 127*w)
                        hi += max(-128*w, 127*w)
                assert -(1 << 31) <= lo <= hi < (1 << 31)
                bits = next(b for b in range(1, 33) if -(1 << (b-1)) <= lo and hi < (1 << (b-1)))
                lanes.append({'oc': group*16+lane, 'bias': bias, 'min': lo, 'max': hi, 'signed_bits': bits})
                lower, upper = min(lower, lo), max(upper, hi)
        rows.append({'op': op, 'kind': d[0], 'channels': cout, 'steps_per_group': steps,
                     'min': lower, 'max': upper, 'signed_bits': max(x['signed_bits'] for x in lanes),
                     'lanes': lanes})

    assert semantic_macs == 11645440, semantic_macs
    report = {'status': 'PASS', 'scope': 'all signed INT8 inputs, fixed weight/bias ROMs; conservative independent-input bound',
              'semantic_MACs': semantic_macs,
              'INT32_no_overflow': True, 'max_required_signed_bits': max(x['signed_bits'] for x in rows),
              'min': min(x['min'] for x in rows), 'max': max(x['max'] for x in rows),
              'ROM_sha256': {name: hashlib.sha256((data/name).read_bytes()).hexdigest()
                             for name in ('descriptors.mem', 'weights.mem', 'bias.mem')},
              'rows': rows, 'RTL_change': False}
    out = args.report
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k not in ('rows', 'ROM_sha256')}))


if __name__ == '__main__':
    main()
