"""JSP-Oct26-Search-Escape-Stall; ©2026 ThomasB. Author: ThomasB."""
import collections,json,pathlib,statistics,sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

root=pathlib.Path(sys.argv[1]);samples=json.loads((root/'curve-samples.json').read_text())
bins=collections.defaultdict(list)
for s in samples:
    if s['meanWorkingEnergy'] is not None:bins[int(s['seconds']//60)].append(s['meanWorkingEnergy'])
x=[s['seconds']/3600 for s in samples]
fig,axes=plt.subplots(3,1,figsize=(10,8),sharex=True,layout='constrained')
fig.suptitle('JSP-Oct26-Search-Escape-Stall: measured 12.24-hour run',fontweight='bold')
axes[0].step(x,[s['wrong'] for s in samples],where='post',color='#d45138')
axes[0].set(ylabel='Incorrect clues',ylim=(0,33),title='Retained best: 13 incorrect clues throughout')
axes[1].step(x,[s['bestEnergy'] for s in samples],where='post',color='#315bff')
axes[1].set(ylabel='Exact energy',ylim=(0,.4),title='Retained best: exact energy unchanged at 0.109975')
keys=sorted(bins);t=[(k+.5)/60 for k in keys]
axes[2].fill_between(t,[min(bins[k]) for k in keys],[max(bins[k]) for k in keys],alpha=.18,color='#315bff',label='Observed range per minute')
axes[2].plot(t,[statistics.median(bins[k]) for k in keys],color='#315bff',linewidth=1,label='Median of worker-mean observations per minute')
axes[2].set(ylabel='Exact energy',xlabel='Real elapsed hours',ylim=(0,.6),title='Working states: ongoing exploration, without a better retained result')
axes[2].legend(loc='upper right',fontsize=8)
for ax in axes:ax.grid(axis='y',alpha=.2);ax.spines[['top','right']].set_visible(False);ax.set_xlim(0,max(x))
fig.text(.75,.005,'©2026 ThomasB · Author: ThomasB',fontsize=8,color='#555')
fig.savefig(root/'JSP-Oct26-Search-Escape-Stall-Energy.png',dpi=180)
