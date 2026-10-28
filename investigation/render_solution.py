#!/usr/bin/env python3
"""Render the verified partition as a static PNG (requires matplotlib)."""
from pathlib import Path
import json
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, Circle

root = Path(__file__).resolve().parent
data = json.loads((root / "verification.json").read_text())
colors = ["#bae6fd", "#c4b5fd", "#fcd34d", "#99f6e4", "#c7d2fe", "#fecaca", "#e2e8f0", "#a5f3fc",
          "#d9f99d", "#fdba74", "#f0abfc", "#cbd5e1", "#f5d0fe", "#ddd6fe", "#a7f3d0", "#fde68a"]
fig, ax = plt.subplots(figsize=(9.3, 9.5), dpi=160)
fig.patch.set_facecolor("white")
caps = {tuple(p) for p in data["capitols"]}
labels = data["labels"]
for r in range(11):
    for c in range(11):
        label = labels[r][c]
        ax.add_patch(Rectangle((c, r), 1, 1, facecolor=colors[label], edgecolor="white", lw=0.6))
        ax.text(c+.5, r+.54, str(data["cell_sizes"][r][c]), ha="center", va="center", fontsize=13, color="#172033")
        if (r+1, c+1) in caps:
            ax.add_patch(Circle((c+.82, r+.19), .065, facecolor="#172033"))
        if r == 0 or labels[r-1][c] != label:
            ax.plot([c, c+1], [r, r], color="#172033", lw=1.4)
        if c == 0 or labels[r][c-1] != label:
            ax.plot([c, c], [r, r+1], color="#172033", lw=1.4)
    ax.text(11.4, r+.54, str(data["row_sums"][r]), va="center", fontsize=11, color="#172033")
ax.plot([0, 11, 11], [11, 11, 0], color="#172033", lw=1.4)
ax.text(11.4, -.35, "Row sum", fontsize=9, va="center", color="#475569")
ax.set_xlim(-.15, 12.7)
ax.set_ylim(11.2, -.65)
ax.set_aspect("equal")
ax.set_xticks([i+.5 for i in range(11)], list(range(1, 12)))
ax.set_yticks([i+.5 for i in range(11)], list(range(1, 12)))
ax.xaxis.tick_top()
ax.tick_params(length=0, labelsize=9, colors="#475569")
for spine in ax.spines.values():
    spine.set_visible(False)
fig.suptitle("Verified partition · answer 408,951", x=.1, y=.97, ha="left", fontsize=19, fontweight="bold", color="#172033")
fig.text(.1, .925, "Numbers = state sizes   •   Dots = capitols   •   All 33 clues verified", fontsize=11, color="#475569")
fig.text(.1, .065, "16 connected symmetric states · 8 capitols · 121 cells", fontsize=11, color="#172033")
fig.text(.1, .035, "Published candidate independently checked in Python and Swift. Uniqueness has not been proved here.", fontsize=8.5, color="#475569")
fig.subplots_adjust(left=.09, right=.99, top=.895, bottom=.09)
fig.savefig(root / "solution.png", dpi=160)
plt.close(fig)
