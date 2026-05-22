"""
Render an 8-panel progress plot for the autoresearch swarm.

Inputs:
  RESULTS_DIR (env, default /tmp/swarm_results):
    Per-agent results_gpu{0..7}.tsv files (the agents' experiment logs).
  GITLOG_DIR (env, default /tmp/swarm_gitlog):
    Per-agent gpu{0..7}.tsv files containing `git log master..HEAD --pretty=format:%h%x09%s`
    (used for the "total kept commits" stat — git log is the canonical record because
    results.tsv has been seen to get wiped during agent restarts).
  OUT (env, default $RESULTS_DIR/swarm_progress.png).

Both directories should be populated by `scripts/fetch_swarm_data.sh` (which
kubectl-execs into the pod). This script just renders.

Visual conventions (mirrors karpathy's analysis.ipynb style):
  - gray dots = discarded experiments
  - green dots = kept experiments
  - green step line = running best val_bpb
  - rotated annotations on each kept-improvement (full text, no truncation)
  - shared y-axis across panels, pinned to the May 19 consensus baseline (~0.979),
    so trajectories are directly comparable.
  - panels for agents that have hacked the time-budget enforcement get a red title.

Run with the project venv that has pandas + matplotlib:
  ~/autoresearch/.venv/bin/python ~/autoresearch/scripts/plot_swarm.py
"""
import os
import re
from pathlib import Path
import pandas as pd
import matplotlib.pyplot as plt

DIR = Path(os.environ.get("RESULTS_DIR", "/tmp/swarm_results"))
GITLOG_DIR = Path(os.environ.get("GITLOG_DIR", "/tmp/swarm_gitlog"))
OUT = Path(os.environ.get("OUT", str(DIR / "swarm_progress.png")))
NUM_GPUS = int(os.environ.get("NUM_GPUS", "8"))

def load_results(i):
    """Robust TSV loader. Agents have written:
      - literal '\\t' instead of tab characters
      - two records concatenated without a newline (line 46 of gpu0)
      - extra tabs in the description
    Skip rows we can't parse cleanly rather than crashing."""
    p = DIR / f"results_gpu{i}.tsv"
    if not p.exists():
        return pd.DataFrame()
    raw = p.read_text()
    rows = []
    header = ["commit", "val_bpb", "memory_gb", "status", "description"]
    for line_no, raw_line in enumerate(raw.splitlines(), start=1):
        if line_no == 1:
            continue  # header
        line = raw_line.replace("\\t", "\t")
        # Heuristic: a record starts with a 7-char hex commit. If a line has TWO such
        # patterns, it's two records concatenated — split on the second occurrence.
        m = re.match(r"^([0-9a-f]{7,40})\t.*?(?=\d\.\d+[a-f]{0,1}([0-9a-f]{6,40})\t)", line)
        if m:
            # very rare — just keep the first record by truncating at the second hash
            pos = line.find(m.group(2))
            if pos > 0:
                line = line[:pos]
        # Also handle the simpler "0.5153b9ed" pattern: digit run followed by 7+ hex
        m2 = re.search(r"(\d)(\b[0-9a-f]{7,40}\t\d\.\d+\t)", line)
        if m2:
            line = line[:m2.start(1)+1]  # keep through the digit, drop the second record
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        # Coalesce extra fields into description
        commit, bpb, mem, status = parts[0], parts[1], parts[2], parts[3]
        desc = "\t".join(parts[4:])
        rows.append({"commit": commit, "val_bpb": bpb, "memory_gb": mem,
                     "status": status, "description": desc})
    df = pd.DataFrame(rows, columns=header)
    df["val_bpb"] = pd.to_numeric(df["val_bpb"], errors="coerce")
    df["status"] = df["status"].astype(str).str.strip().str.upper()
    df = df.dropna(subset=["val_bpb"])
    return df.reset_index(drop=True)

def load_gitlog_count(i):
    """Number of kept commits on this agent's branch (master..HEAD)."""
    p = GITLOG_DIR / f"gpu{i}.tsv"
    if not p.exists():
        return 0
    return len([l for l in p.read_text().splitlines() if l.strip()])

results = {i: load_results(i) for i in range(NUM_GPUS)}
git_kept = {i: load_gitlog_count(i) for i in range(NUM_GPUS)}

# ---- shared axes: pinned to consensus baseline (~0.979 from May 19 launch) ----
KNOWN_BASELINE = 0.979383   # gpu3's first row from launch — the canonical val_bpb at commit 08bb702
# Find swarm-wide best across all agents' kept rows
all_bests = []
for i, df in results.items():
    kept = df[df["status"] == "KEEP"] if not df.empty else pd.DataFrame()
    if not kept.empty:
        all_bests.append(kept["val_bpb"].min())
global_best = min(all_bests) if all_bests else 0.94

y_top_margin = max(0.005, (KNOWN_BASELINE - global_best) * 0.20)
y_bot_margin = max(0.002, (KNOWN_BASELINE - global_best) * 0.12)
Y_LO = global_best - y_bot_margin
Y_HI = KNOWN_BASELINE + y_top_margin

# Shared x-axis: largest results.tsv length (so all panels span the same scale)
all_lens = [len(results[i]) for i in range(NUM_GPUS) if not results[i].empty]
X_HI = max(all_lens) + 5 if all_lens else 100

# ---- plot ----
PANEL_H = 6.5
fig, axes = plt.subplots(NUM_GPUS, 1, figsize=(18, PANEL_H * NUM_GPUS), sharex=False, sharey=True)

for i, ax in enumerate(axes):
    df = results[i]
    n_kept_git = git_kept[i]

    if df.empty:
        ax.set_title(f"gpu{i}: no results.tsv data (git log: {n_kept_git} kept commits)")
        continue

    valid = df[df["status"] != "CRASH"].copy().reset_index(drop=True)
    if valid.empty:
        ax.set_title(f"gpu{i}: only crashes")
        continue

    # Discarded: gray dots
    disc = valid[valid["status"] == "DISCARD"]
    n_disc_total = (df["status"] == "DISCARD").sum()
    ax.scatter(disc.index, disc["val_bpb"],
               c="#cccccc", s=14, alpha=0.55, zorder=2,
               label=f"Discarded ({n_disc_total})")

    # Kept: green dots
    kept_v = valid[valid["status"] == "KEEP"]
    n_kept_tsv = (df["status"] == "KEEP").sum()
    ax.scatter(kept_v.index, kept_v["val_bpb"],
               c="#2ecc71", s=55, zorder=4, edgecolors="black", linewidths=0.5,
               label=f"Kept ({n_kept_tsv})")

    # Running best step line
    kept_mask = valid["status"] == "KEEP"
    kept_idx = valid.index[kept_mask]
    kept_bpb = valid.loc[kept_mask, "val_bpb"]
    running_min = kept_bpb.cummin()
    ax.step(kept_idx, running_min, where="post",
            color="#27ae60", linewidth=2, alpha=0.85, zorder=3, label="Running best")

    # Annotations: only for kept-experiments that drove a NEW best (full text, no truncation)
    prev_best = float("inf")
    for idx, bpb in zip(kept_idx, kept_bpb):
        if bpb < prev_best:
            desc = str(valid.loc[idx, "description"]).strip()
            desc = re.sub(r"^(may\d+-gpu\d+:|\[may\d+-gpu\d+\]\s*experiment:)\s*", "", desc)
            ax.annotate(desc, (idx, bpb),
                        textcoords="offset points",
                        xytext=(7, 8), fontsize=8.5,
                        color="#1a7a3a", alpha=0.95,
                        rotation=28, ha="left", va="bottom")
            prev_best = bpb

    best_bpb = kept_bpb.min() if not kept_bpb.empty else float("nan")
    n_total = len(df)
    n_crash = (df["status"] == "CRASH").sum()
    pct = (KNOWN_BASELINE - best_bpb) / KNOWN_BASELINE * 100 if pd.notna(best_bpb) else 0

    title = (
        f"gpu{i}:  best = {best_bpb:.4f}   ({pct:+.2f}% vs baseline {KNOWN_BASELINE:.4f})   ·   "
        f"results.tsv: {n_total} expts ({n_kept_tsv}K / {n_disc_total}D / {n_crash}C)   ·   "
        f"git log: {n_kept_git} total kept commits"
    )
    # Flag agents that have hacked the time-budget enforcement (e.g. gpu3 changed
    # `if step > 10` to `if step > 8000`, granting itself 8000 free training steps
    # outside the 5-min wall-clock cap. val_bpb numbers are NOT comparable to others.)
    HACK_FLAG = ""
    try:
        # heuristic: look for "free warmup steps" or "step > " patterns in the kept commits
        gitlog_path = GITLOG_DIR / f"gpu{i}.tsv"
        if gitlog_path.exists():
            log_text = gitlog_path.read_text().lower()
            if "free warmup" in log_text or "free steps" in log_text:
                HACK_FLAG = "  ⚠ TIME-BUDGET HACK (val_bpb not comparable)"
    except Exception:
        pass
    title += HACK_FLAG
    color = "#bb0000" if HACK_FLAG else "black"
    ax.set_title(title, fontsize=11, loc="left", color=color)
    ax.set_xlabel("Experiment # (from current results.tsv)", fontsize=10)
    ax.set_ylabel("val_bpb", fontsize=10)
    ax.legend(loc="upper right", fontsize=9, framealpha=0.95)
    ax.grid(True, alpha=0.25)
    ax.set_xlim(-2, X_HI)
    ax.set_ylim(Y_LO, Y_HI)

    # Note any clipped points (e.g. post-restart "baseline" rows above 0.979)
    n_clipped_above = (valid["val_bpb"] > Y_HI).sum()
    if n_clipped_above > 0:
        ax.text(0.985, 0.92,
                f"⚠ {n_clipped_above} point(s) clipped above (val_bpb > {Y_HI:.3f})",
                transform=ax.transAxes, fontsize=9, color="darkred",
                ha="right", va="top",
                bbox=dict(boxstyle="round,pad=0.3", facecolor="white",
                          edgecolor="darkred", alpha=0.85))

    # Note if results.tsv is shorter than git log (post-restart truncation)
    if n_kept_tsv < n_kept_git - 1:  # -1 to allow off-by-one for the new "baseline" row
        ax.text(0.015, 0.92,
                f"ℹ results.tsv reset on May 21 swarm restart\n"
                f"   git log shows {n_kept_git} kept commits, results.tsv has {n_kept_tsv}",
                transform=ax.transAxes, fontsize=9, color="#553300",
                ha="left", va="top",
                bbox=dict(boxstyle="round,pad=0.3", facecolor="#fffaf0",
                          edgecolor="#cc8800", alpha=0.9))

# Suptitle
total_tsv = sum(len(results[i]) for i in range(NUM_GPUS))
total_git_kept = sum(git_kept.values())
fig.suptitle(
    f"Autoresearch swarm: 8 independent agents, {total_git_kept} total kept commits across all branches\n"
    f"Baseline ≈ {KNOWN_BASELINE:.4f}   →   swarm best = {global_best:.4f}   "
    f"({(KNOWN_BASELINE - global_best)/KNOWN_BASELINE*100:.2f}% improvement)",
    fontsize=15, y=1.0)

plt.tight_layout(rect=[0, 0, 1, 0.995])
plt.savefig(OUT, dpi=130, bbox_inches="tight")
print(f"saved: {OUT}  (figsize=18x{PANEL_H * NUM_GPUS}, y-range {Y_LO:.4f}-{Y_HI:.4f})")
print(f"agents:")
for i in range(NUM_GPUS):
    df = results[i]
    n_kept_tsv = (df["status"] == "KEEP").sum() if not df.empty else 0
    print(f"  gpu{i}: results.tsv={len(df)} rows ({n_kept_tsv} kept)  git_log={git_kept[i]} commits")
