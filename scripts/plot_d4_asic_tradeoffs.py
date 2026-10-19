#!/usr/bin/env python3
"""Three separate area scopes, read directly from retained acceptance evidence."""
import json
from pathlib import Path
import re
import tarfile
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parents[1]
with tarfile.open(str(ROOT / 'artifacts/d4_asic_stage2_evidence_20261020.tar.gz')) as tar:
    lane = []
    for style in ('partial', 'native'):
        text = tar.extractfile('build/reports/asic_rq_{}_tt_20261019/area.rpt'.format(style)).read().decode()
        lane.append(float(re.search(r'Total cell area:\s+([\d.eE+-]+)', text).group(1)) / 1e6)
memory = json.loads((ROOT / 'artifacts/d4_asic_macro_area_scope_20261020.json').read_text())
synth = json.loads((ROOT / 'artifacts/d4_asic_synth_root_acceptance_20261020.json').read_text())['metrics']
plt.rcParams.update({'font.size': 10, 'axes.spines.top': False, 'axes.spines.right': False,
                     'pdf.fonttype': 42, 'axes.titleweight': 'bold'})
fig, axes = plt.subplots(1, 3, figsize=(12.5, 4.6), gridspec_kw={'wspace': 0.4})
colors = ['#607d9a', '#32978b']
values = [lane, [memory['LEF_and_Liberty_macro_area_before_um2']/1e6,
                 memory['LEF_and_Liberty_macro_area_after_um2']/1e6]]
labels = [('Four partial\nproducts', 'Native full\nsigned32'), ('3 x 2048\nwords', '2048/1024/2048\nwords')]
titles = ['Isolated RQ lane', 'Activation SRAM footprint']
for ax, numbers, ticks, title in zip(axes[:2], values, labels, titles):
    bars = ax.bar([0, 1], numbers, color=colors, width=0.6)
    ax.set_xticks([0, 1]); ax.set_xticklabels(ticks)
    ax.set_title(title); ax.set_ylabel('Area (mm$^2$)')
    ax.set_ylim(0, max(numbers)*1.3)
    for bar, value in zip(bars, numbers):
        ax.text(bar.get_x()+bar.get_width()/2, value+max(numbers)*.035,
                '{:.4f}'.format(value), ha='center')
    ax.text(.5, .91, '{:.2%} smaller'.format(1-numbers[1]/numbers[0]),
            transform=ax.transAxes, ha='center', color='#236d61')
axes[0].set_xlabel('TT, 8 ns; mapped standard cells')
axes[1].set_xlabel('Exact LEF/Liberty placement boundary')
ax = axes[2]
bottom = [0, 0]
for key, title, color in [('macro_area_um2', 'Memory macros', '#607d9a'),
                          ('combinational_area_um2', 'Combinational', '#dfa45c'),
                          ('noncombinational_area_um2', 'Sequential', '#32978b')]:
    numbers = [synth['candidates'][c][key]/1e6 for c in ('A2', 'A3')]
    ax.bar([0, 1], numbers, bottom=bottom, width=.6, label=title, color=color)
    bottom = [b+n for b, n in zip(bottom, numbers)]
for x, total in enumerate(bottom):
    ax.text(x, total+.18, '{:.4f}'.format(total), ha='center')
ax.set_xticks([0, 1]); ax.set_xticklabels(['A2: logic\nresidual table', 'A3: 8 compiled\nresidual ROMs'])
ax.set_title('Complete core, all storage counted'); ax.set_ylabel('Cell area (mm$^2$)')
ax.set_ylim(0, 13.2); ax.set_xlabel('TT, 10 ns; synthesis only')
ax.legend(loc='upper left', frameon=False, fontsize=8)
ax.text(.98, .91, '+{:.2%} total'.format(synth['A3_total_area_increase_fraction_vs_A2']),
        transform=ax.transAxes, ha='right', color='#9f5a20')
fig.suptitle('D4 / SMIC 180 nm: measured implementation trade-offs', fontsize=14, fontweight='bold', y=.98)
fig.text(.5, .045, 'Same frozen network and integer semantics. Separate area scopes; no power or post-route claim.\n'
         'A2 numeric mapping reports retained; its mapped checkpoint was not saved. A3 checkpoint and report recovery verified.',
         ha='center', fontsize=8, color='#555555')
fig.subplots_adjust(top=.83, bottom=.26)
out = ROOT / 'docs/reports/assets'
out.mkdir(parents=True, exist_ok=True)
for ext in ('png', 'pdf'):
    fig.savefig(str(out / ('d4_asic_area_tradeoffs_20261020.' + ext)), dpi=180)
print('D4_ASIC_AREA_FIGURE_WRITTEN')
