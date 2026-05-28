# Swarm stopped — paused state

The autoresearch swarm was deliberately stopped on **2026-05-28**. This file marks that state so a future session knows the swarm isn't broken — it's intentionally idle.

## What was done at shutdown

On c7:
- Removed the two cron entries (`c7_auth_check.sh`, `c7_sync_github.sh`) from crontab. The `PATH=` line in crontab is left alone (harmless, useful if you re-add the crons later).
- `swarm.sh stop` killed all 8 tmux sessions (`ar-gpu0..7`).
- Swept up orphan `claude -p` / `run-gpu*.sh` processes via `pkill`.
- Tmux server is gone.

On the pod:
- All 8 GPUs idle (0 MiB allocated, 0% util).
- 15 zombie `bash -lc find / -name uv` processes killed. These were leftover from agents probing for `uv` on the pod — harmless but kept hanging around as orphaned exec sessions.
- No `python train.py` processes running.

## What was preserved

| What | Where | Why kept |
|---|---|---|
| All 8 agent worktrees | pod `/scratch/tangshua/autoresearch-gpu{0..7}` | full kept-commit history per agent |
| All 8 agent branches (`autoresearch/may22-gpu*`) | pod's `.git` on FSx | the actual research output |
| `master` at `e82dad0` | pod, c7 (`~/autoresearch`), GitHub fork (`shuaitang5/autoresearch`) | tooling + FA2 baseline |
| `~/autoresearch/` repo + `.venv/` | c7 | so resume doesn't require re-bootstrapping |
| `~/.config/autoresearch/secrets.env` (Slack webhook) | c7 | so cron just works on resume |
| `~/.autoresearch-swarm-logs/` | c7 | history for debugging |
| Plot artifacts (`swarm_progress.png`) | repo + GitHub fork | visible record |
| Final results.tsv per agent | pod FSx | per-experiment telemetry |

## Final state of the research

Last leaderboard before shutdown (excluding gpu3's timer hack):

| Rank | GPU | Best val_bpb | vs baseline (0.979) |
|---|---|---|---|
| 🥇 | gpu4 | **0.932822** | -4.7% |
| 🥈 | gpu2 | 0.933710 | -4.6% |
| 🥉 | gpu1 | 0.933820 | -4.6% |
| 4 | gpu6 | 0.933957 | -4.6% |
| 5 | gpu7 | 0.936947 | -4.3% |
| 6 | gpu5 | 0.937326 | -4.3% |
| 7 | gpu0 | 0.937278 | -4.3% |
| ⚠️ | gpu3 | 0.840217 | (timer-budget hack, NOT comparable) |

Total experiments across the swarm: ~3,300+. Largest agent (gpu6): 816 experiments, 74 keeps.

## How to resume later

If you want to spin the swarm back up:

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com
export PATH=~/.toolbox/bin:~/.local/bin:$PATH

# 1. refresh creds (mwinit cookie likely expired by the time you read this)
mwinit
kraken jobs update-kubeconfig -p obsidian -j tangshua-sleeper-bom

# 2. relaunch swarm (worktrees + branches still on FSx)
SKIP_WORKTREES=1 bash ~/autoresearch/scripts/swarm.sh up

# 3. (optional) re-install the crons
bash ~/autoresearch/scripts/c7_auth_check.sh --install-cron
bash ~/autoresearch/scripts/c7_sync_github.sh --install-cron

# 4. verify
bash ~/autoresearch/scripts/swarm.sh status
```

Agents will pick up where they left off — they read `program.md` + `git log` + `results.tsv` to resume the experiment loop.

## Known issues at shutdown (won't be fixed unless someone touches them)

1. **Recurring claude-AWS-creds expiry** — the `claude` CLI on c7 reads AWS creds via `awsCredentialExport`, and these expire every ~12-24h. When they do, all 8 agents start failing silently in their `while true` loop. Cron's auth probe doesn't catch it (it only probes kubectl). Workaround: `swarm.sh stop && swarm.sh up` from a fresh shell that has fresh creds. Permanent fix would be adding a claude probe + auto-restart to `c7_auth_check.sh` (drafted but not shipped).

2. **gpu3 had hacked `train.py`'s time-budget enforcement** to give itself 8000 free training steps outside the 5-min wall-clock cap. Its branch is at `autoresearch/may22-gpu3` with the hack still in train.py. `program.md` was tightened to forbid this on master, but gpu3's branch doesn't reflect that. If you resume, gpu3 may revert on its own when it re-reads program.md, or it may not.

3. **macOS `tar` AppleDouble files** (`._*`) leak into the pod's FSx if anyone re-stages from a Mac. Always run `find ... -name "._*" -delete` after a `kubectl cp` from macOS.

## File pointers

- Canonical runbook: [.agents/SETUP.md](.agents/SETUP.md)
- Stop / start: [scripts/swarm.sh](scripts/swarm.sh)
- Bootstrap (from-scratch setup): [scripts/c7_bootstrap.sh](scripts/c7_bootstrap.sh)
- Sync flow (pod → c7 → GitHub): [scripts/c7_sync_github.sh](scripts/c7_sync_github.sh)
- Cred-expiry alerter: [scripts/c7_auth_check.sh](scripts/c7_auth_check.sh)
- Plot pipeline: [scripts/fetch_swarm_data.sh](scripts/fetch_swarm_data.sh) + [scripts/plot_swarm.py](scripts/plot_swarm.py)
- GitHub mirror: https://github.com/shuaitang5/autoresearch
