"""Plot comparable measured cycles; do not mix synthesis/route or power results."""
import hashlib
import json
import re
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def main():
    root = Path(__file__).resolve().parents[1]
    variants = [
        ('E\nserial groups', 'affine_packed_20261018'),
        ('F/G\nresidual pipeline', 'regcontrol_20261018'),
        ('I2\nstaged MAC/RQ', 'biased_round_20261018'),
        ('J\ncontinuous groups', 'continuous_groups_20261018'),
        ('K2\n4-lane residual', 'ram_ports_20261018'),
    ]
    rows = []
    for label, tag in variants:
        path = root / f'build/reports/d4_fullnet_{tag}/sample_0_mode0.log'
        match = re.search(r'D4_PACKED_FULLNET_PASS mode=0 epoch=0 cycles=(\d+) '
                          r'tap_words=24336 logits=10 macs=11645440', path.read_text())
        assert match, path
        rows.append({'label': label, 'cycles': int(match[1]),
                     'log': str(path.relative_to(root)),
                     'log_sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    accounting = json.loads((root/'build/reports/d4_k2_cycle_accounting_20261018.json').read_text(encoding='utf-8-sig'))
    parts = [('Conv issue', 230016), ('Conv startup/drain', 416),
             ('Residual', 23573), ('GAP + FC', 647), ('Input/start', 4097)]
    assert sum(x[1] for x in parts) == accounting['latency_cycles'] == rows[-1]['cycles']
    assert accounting['conv_issue_cycles'] == parts[0][1]
    assert accounting['conv_measured_cycles'] == parts[0][1]+parts[1][1]
    assert accounting['other_start_transfer_boundary_cycles'] == parts[-1][1]
    colors = ['#bbc9d6', '#9db5ca', '#7e9fbd', '#4c7ca6', '#27577f']
    fig, (ax, detail) = plt.subplots(1, 2, figsize=(11.5, 5), gridspec_kw={'width_ratios': [2.1, 1]})
    bars = ax.bar(range(len(rows)), [x['cycles']/1000 for x in rows], color=colors, width=.65)
    for bar, row in zip(bars, rows):
        ax.text(bar.get_x()+bar.get_width()/2, bar.get_height()+9, f"{row['cycles']:,}", ha='center', fontsize=9)
    ax.set_xticks(range(len(rows)), [x['label'] for x in rows], fontsize=9)
    ax.set_ylim(0, 610)
    ax.set_ylabel('Full inference cycles (thousands)')
    ax.set_title('Measured no-backpressure cycles', fontsize=12)
    ax.grid(axis='y', alpha=.2)
    ax.set_axisbelow(True)
    part_colors = ['#27577f', '#cf9a36', '#81a7b6', '#a4b89e', '#c9d3dd']
    bottom = 0
    for (label, cycles), color in zip(parts, part_colors):
        pct = cycles/rows[-1]['cycles']*100
        detail.bar(0, cycles/1000, bottom=bottom/1000, width=.6, color=color,
                   label=f'{label}: {cycles:,} ({pct:.2f}%)')
        bottom += cycles
    detail.set_xlim(-.65, .65)
    detail.set_ylim(0, 290)
    detail.set_xticks([0], ['K2'])
    detail.set_title('K2 cycle accounting', fontsize=12)
    detail.set_ylabel('Cycles (thousands)')
    detail.legend(loc='upper center', bbox_to_anchor=(.5, -.10), frameon=False, fontsize=8)
    for axis in (ax, detail):
        axis.spines[['top', 'right']].set_visible(False)
    fig.suptitle('Frozen D4: full-network RTL scheduling', fontsize=15)
    fig.text(.03, .02, 'Same INT8/INT32 network; 23,290,880 ops; all input beats included. Functional cycles only.', fontsize=9)
    fig.subplots_adjust(left=.07, right=.97, top=.83, bottom=.28, wspace=.38)
    out = root/'docs/reports/assets/d4_fullnet_cycles_20261018'
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out.with_suffix('.png'), dpi=220)
    fig.savefig(out.with_suffix('.svg'))
    out.with_suffix('.json').write_text(json.dumps({'variants': rows, 'K2_parts': parts}, indent=2)+'\n')
    print(json.dumps({'png': str(out.with_suffix('.png')), 'source_logs': len(rows), 'K2_cycles': rows[-1]['cycles']}))


if __name__ == '__main__':
    main()
