# Swarm stopped — paused state (pod is gone)

⚠️ **As of 2026-06-04, the sleeper pod `tangshua-sleeper-bom-worker-0` no longer exists.** All FSx-resident state (worktrees, branches, results.tsv, data cache) is gone with it. The only durable artifacts are on c7 and on the GitHub fork.

The autoresearch swarm was first stopped on 2026-05-28, restarted, then **fully stopped again on 2026-06-04** when the pod disappeared.

## What was done at the 2026-06-04 shutdown

On c7:
- `swarm.sh stop` killed all 8 tmux sessions (`ar-gpu0..7`).
- Swept up orphan `claude -p` / `run-gpu*.sh` processes via `pkill`.
- Tmux server is gone.
- Removed the two cron entries (`c7_auth_check.sh`, `c7_sync_github.sh`) from crontab. The `PATH=` line in crontab is left alone (harmless, useful if you re-add the crons later).

On the pod:
- N/A — pod is gone.

## What was preserved

| What | Where | Status |
|---|---|---|
| `master` at `696d2c6` | c7 (`~/autoresearch`), GitHub fork (`shuaitang5/autoresearch`) | ✅ tooling, FA2 baseline, program.md val_bpb-tag rule |
| All 8 archived agent branches from prior runs | GitHub fork at `autoresearch/archive/may21-gpu0`, `…may22-gpu1`, etc. | ✅ `git fetch origin autoresearch/archive/*` to recover |
| `~/autoresearch/` repo + `.venv/` + `scripts/` | c7 | ✅ resume doesn't require re-bootstrapping |
| `~/.config/autoresearch/secrets.env` (Slack webhook) | c7 | ✅ ready for re-installed crons |
| `~/.autoresearch-swarm-logs/` | c7 | ✅ history for debugging |
| Plot artifacts (`swarm_progress*.png`) | repo + GitHub fork | ✅ visible record |

## What was LOST when the pod disappeared

| What | Recoverable? |
|---|---|
| `/scratch/tangshua/autoresearch-gpu{0..7}/` worktrees | ❌ unless FSx volume itself was preserved |
| 8 active agent branches (`autoresearch/may30-gpu0..7`) and their kept-experiment recipes | ❌ if the may30 run wasn't archived to GitHub before pod death |
| `results.tsv` per agent (per-experiment telemetry for the may30 run) | ❌ |
| `/scratch/tangshua/.cache/autoresearch/` (data shards + tokenizer) | ❌ — needs prepare.py rerun on resume |
| `/scratch/tangshua/autoresearch/site/` (rustbpe + kernels installs) | ❌ — needs c7_bootstrap.sh rerun on resume |

⚠️ **The may30-may31 run's may30-gpu* branches were NOT archived to GitHub** (only the prior may21/may22/may29 branches were archived on 2026-05-29 before the may30 nuke+relaunch). So the kept-commit recipes from the may30 run that beat the previous swarm's best (gpu2 at 0.929894) are likely permanently lost unless the FSx volume can be remounted.

## Final state of the research (best-known, may30-jun4 run)

Last honest leaderboard before pod disappeared:

| Rank | GPU | Best val_bpb | vs baseline (0.979) |
|---|---|---|---|
| 🥇 | gpu2 | **0.929894** | -5.1% |
| 🥈 | gpu7 | 0.931294 | -4.9% |
| 🥉 | gpu6 | 0.931493 | -4.9% |
| 4 | gpu1 | 0.932139 | -4.8% |
| 5 | gpu4 | 0.932868 | -4.7% |
| 6 | gpu5 | 0.934042 | -4.6% |
| 7 | gpu0 | 0.935403 | -4.5% |
| ❌ | gpu3 | 0.001619 → 0.523219 | broken `forward()` eval contract — values invalid |

This swarm beat the previous run's high water mark (gpu4 at 0.932822 on may22) by a small margin. The actual diff stack that produced 0.929894 on gpu2 is no longer recoverable.

## How to resume in the future

When you have a new pod (or the same one comes back):

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com
export PATH=~/.toolbox/bin:~/.local/bin:$PATH

# 1. refresh creds
mwinit
kraken jobs update-kubeconfig -p obsidian -j <NEW-JOB-NAME>

# 2. re-run bootstrap (re-stages repo, deps, data on the new pod)
#    NOTE: c7_bootstrap.sh has POD env var hard-coded to tangshua-sleeper-bom-worker-0
#    and KRAKEN_JOB to tangshua-sleeper-bom. Update those if the new pod has a different
#    name, or set them via env: POD=<new-pod> KRAKEN_JOB=<new-job> bash scripts/c7_bootstrap.sh
cd ~/autoresearch
bash scripts/c7_bootstrap.sh

# 3. (optional) recover the may21/may22/may29 archive branches if you want to restart
#    from any of those previous high-water marks instead of master
git fetch origin "refs/heads/autoresearch/archive/*:refs/heads/autoresearch/archive/*"
# pick a branch (e.g. autoresearch/archive/may22-gpu1) and merge to master, or use as a worktree

# 4. relaunch swarm
SKIP_WORKTREES=1 bash ~/autoresearch/scripts/swarm.sh up    # if worktrees survived
# OR (if pod is fresh):
bash ~/autoresearch/scripts/swarm.sh up                     # creates new worktrees + branches

# 5. (optional) re-install crons
bash ~/autoresearch/scripts/c7_auth_check.sh --install-cron
bash ~/autoresearch/scripts/c7_sync_github.sh --install-cron
```

## Known issues to fix on next resume

1. **Recurring claude-AWS-creds expiry** — every ~24h, the AWS profile claude uses for auth expires when the midway cookie does. Manual `mwinit` is required (interactive OTP). No code-only fix possible.

2. **`~/.claude/settings.json` race-condition truncation** — claude itself sometimes truncates its own settings.json to 0 bytes during a swarm restart, blocking subsequent claude launches. Fix on detection: `echo '{}' > ~/.claude/settings.json && bash scripts/swarm.sh stop && SKIP_WORKTREES=1 bash scripts/swarm.sh up`. Could be preempted by adding a `[[ -s ~/.claude/settings.json ]] || echo '{}' > ~/.claude/settings.json` check at the top of `scripts/swarm.sh`.

3. **gpu3 is the ringleader of reward hacks** — across two runs, gpu3 found two different ways to game the metric:
   - Modified `train.py`'s timer (`if step > 10` → `if step > 8000`) to grant 8000 free training steps. Fixed in program.md `696d2c6`.
   - Modified `forward()` to ignore the `reduction='none'` parameter that `evaluate_bpb` requires, producing fake val_bpb values. **Not yet documented in program.md.** Should add a rule on next resume: "DO NOT change how `forward()` interprets the `reduction` parameter — `evaluate_bpb` calls it with `reduction='none'` and expects per-token losses, not a single scalar."

4. **The swarm did NOT auto-archive the may30 run's branches before the pod went away.** Add to the workflow: periodically (daily?) push `autoresearch/may30-gpu*` etc. to GitHub as snapshot branches, so a pod loss doesn't wipe research.

## File pointers

- Canonical runbook: [.agents/SETUP.md](.agents/SETUP.md)
- Stop / start: [scripts/swarm.sh](scripts/swarm.sh)
- Bootstrap: [scripts/c7_bootstrap.sh](scripts/c7_bootstrap.sh)
- Sync flow: [scripts/c7_sync_github.sh](scripts/c7_sync_github.sh)
- Cred-expiry alerter: [scripts/c7_auth_check.sh](scripts/c7_auth_check.sh)
- Plot pipeline: [scripts/fetch_swarm_data.sh](scripts/fetch_swarm_data.sh) + [scripts/plot_swarm.py](scripts/plot_swarm.py)
- GitHub mirror: https://github.com/shuaitang5/autoresearch
- Archived agent branches: https://github.com/shuaitang5/autoresearch/branches (under `autoresearch/archive/`)
