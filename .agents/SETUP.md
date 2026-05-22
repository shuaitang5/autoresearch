# autoresearch swarm: c7-only runbook

Run [karpathy/autoresearch](https://github.com/karpathy/autoresearch) as an **8-agent swarm** on a Leviathan B200 sleeper pod. **Everything happens on `c7` cloud desktop.** Your laptop is only used to ssh into c7.

> **For a fresh Claude Code session:** read [OPERATIONS](#operations-fresh-session-pickup) below first. It tells you (a) how to check current state, (b) how to resume after a c7 reboot, and (c) where progress lives. Don't re-read setup unless you're starting from scratch.

---

## OPERATIONS — fresh session pickup

If you're a Claude session that just got dropped into this repo with no prior context, here's the cheat sheet:

### What's running (as of 2026-05-19, ongoing)

- **8-agent autoresearch swarm**, one tmux session per GPU, on cloud desktop `c7`.
- **c7** = `dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com` (alias `c7` on user's laptop).
- **Pod** = `tangshua-sleeper-bom-worker-0` in Leviathan BOM cluster (kraken job: `tangshua-sleeper-bom`).
- All experiment state on FSx at `/scratch/tangshua/`. **Nothing important lives on c7's local disk** except the launcher scripts in `~/autoresearch/scripts/` and per-agent runner logs in `~/.autoresearch-swarm-logs/`.

### How to check status (run on user's laptop, talks to c7)

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com '
  bash ~/autoresearch/scripts/swarm.sh status
'
```

You should see 8 lines, all `RUNNING`. If any are `DOWN`, see [Resume](#resume-after-c7-reboot-or-tmux-loss).

For research progress (val_bpb numbers, what each agent is keeping/discarding):

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com '
  export PATH=$HOME/.toolbox/bin:$PATH
  for i in 0 1 2 3 4 5 6 7; do
    echo "=== gpu$i ==="
    kubectl exec tangshua-sleeper-bom-worker-0 -- bash -c "
      cd /scratch/tangshua/autoresearch-gpu$i
      tail -10 results.tsv
      echo ---
      git log --oneline -5
    "
  done
'
```

For real-time GPU utilization:

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com '
  export PATH=$HOME/.toolbox/bin:$PATH
  kubectl exec tangshua-sleeper-bom-worker-0 -- nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader
'
```

To watch one agent live:

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com -t '
  bash ~/autoresearch/scripts/swarm.sh attach 0
'
# Ctrl-B then D to detach without killing the agent.
```

### Where progress is saved

| Thing | Lives at | Survives… |
|---|---|---|
| The `train.py` an agent is iterating on | `/scratch/tangshua/autoresearch-gpu<i>/train.py` (FSx) | c7 reboot, pod reboot |
| Each agent's commit history (every kept experiment is a commit) | `/scratch/tangshua/autoresearch-gpu<i>/.git` (worktree of `/scratch/tangshua/autoresearch/.git` on FSx) | c7 reboot, pod reboot |
| Each agent's `results.tsv` (every experiment, kept + discarded + crashed) | `/scratch/tangshua/autoresearch-gpu<i>/results.tsv` (FSx, not git-tracked) | c7 reboot, pod reboot |
| Tmux sessions running `claude -p` | `/tmp/tmux-<uid>/...` on c7 (in-memory) | survives ssh disconnect, **NOT** c7 reboot |
| Per-agent runner stdout (claude's text output) | `~/.autoresearch-swarm-logs/gpu<i>.log` on c7 | c7 disk persistent (not on FSx) |
| Cron auth-probe log | `~/.cache/autoresearch-auth/probe.log` on c7 | c7 disk persistent |

The single source of truth for "what has the agent learned" is the **git history of each per-gpu worktree on FSx**. Even if every other piece of state is wiped, the agents can resume from there.

### Resume after c7 reboot (or tmux loss)

c7 reboots kill the tmux server (in-memory), which kills all 8 agents. The work itself is safe — everything important lives on FSx (worktrees, branches, results.tsv) or local disk that survives reboot (scripts, .venv, ~/.config/autoresearch/secrets.env, ~/.midway/cookie, ~/.kube/config, crontab).

#### What actually breaks across a c7 reboot

| What | Survives c7 reboot? | Why |
|---|---|---|
| Pod + FSx state (worktrees, branches, results.tsv, all kept commits) | ✅ | Different machine. `/scratch/tangshua/` is on remote FSx. |
| `~/.toolbox/bin/{claude,kraken,mwinit}` | ✅ | Local disk |
| `~/.local/bin/{uv,gh}` | ✅ | Local disk |
| `~/autoresearch/` (scripts, .venv, etc.) | ✅ | Local disk |
| `~/.midway/cookie` (midway auth) | ✅ for ~20h | File-based; expires by time, not reboot |
| `~/.config/autoresearch/secrets.env` | ✅ | Local disk |
| Crontab (auth check + sync) | ✅ | Crontab is file-based, fires automatically once kubectl auth is fresh |
| `~/.kube/config` (kubectl context) | ✅ | But the kraken-issued AWS creds inside it expire |
| AWS profile creds (used by `claude` and `kubectl`) | ❌ | Cached briefly via `ada`; expire after a few hours |
| **8 tmux sessions running `claude -p`** | ❌ | Tmux server is in-memory; reboot kills it |

#### The full resume procedure (manual, 2-3 minutes)

```bash
# 1. ssh in (laptop)
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com

# 2. set PATH (your interactive shells should have this via .bashrc, but be explicit)
export PATH=~/.toolbox/bin:~/.local/bin:$PATH

# 3. refresh creds (this also fixes both kubectl AND claude — they share the AWS profile)
mwinit                                                                 # only if midway cookie >12h old
kraken jobs update-kubeconfig -p obsidian -j tangshua-sleeper-bom

# 4. relaunch the 8-agent swarm
SKIP_WORKTREES=1 bash ~/autoresearch/scripts/swarm.sh up

# 5. verify (~2 min later, give agents time to start their first train.py)
bash ~/autoresearch/scripts/swarm.sh status                            # should show 8 RUNNING
ssh c7 'export PATH=$HOME/.toolbox/bin:$PATH && kubectl exec tangshua-sleeper-bom-worker-0 -- nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader'
```

#### Critical: `SKIP_WORKTREES=1`

Without it, `swarm.sh up` tries `git worktree add` on already-existing worktrees and errors out. With it, swarm.sh:
- Skips the `git worktree add` step
- Skips creating `results.tsv` (preserves the experiment history that's already there)
- Just spins up the 8 tmux sessions on top of existing FSx state

#### The agent's behavior on resume

When `claude -p` is relaunched by the runner, the runner script's iteration counter starts at 0, so the agent gets the **kickoff prompt** again. The kickoff prompt has been hardened to tell the agent:
- Branch already exists (skip `git checkout -b`)
- `results.tsv` already exists (skip "initialize results.tsv" — DO NOT OVERWRITE IT)

The agent then reads program.md, looks at the current git state (its own kept-commit history) and `results.tsv`, and continues the experiment loop. **No regression in val_bpb is expected.**

#### If something doesn't come back

- **All GPUs idle 5 min after `swarm.sh up`**: claude is failing auth. Check `tail ~/.autoresearch-swarm-logs/gpu0.log` — if you see `awsCredentialExport did not return a valid value`, redo step 3.
- **`swarm.sh status` shows DOWN sessions**: tmux sessions didn't spawn. Check that `/apollo/env/envImprovement/bin/tmux` exists (system tmux at `/usr/bin/tmux` is too old).
- **Stuck on stale env from before reboot**: do `swarm.sh stop` then `swarm.sh up` from a fresh shell so the tmux sessions inherit current env.

### If the auth cron alert fires

Slack message will look like 🚨 with `kubectl exec failed: ... Unauthorized` and a fix block. Just SSH to c7 and run those exact lines:

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com
export PATH=~/.toolbox/bin:$PATH
mwinit                                                       # if midway cookie expired
kraken jobs update-kubeconfig -p obsidian -j tangshua-sleeper-bom
```

The agents themselves do **not** need a restart — when their next `kubectl exec` retries, it'll succeed. Their `claude -p` may have crashed mid-loop (the runner script will respawn it within 30s).

### Stopping (be sure)

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com '
  bash ~/autoresearch/scripts/swarm.sh stop                  # kill tmux only; FSx state stays
  # or
  bash ~/autoresearch/scripts/swarm.sh nuke                  # ALSO delete worktrees + branches (destructive)
'
```

### Files a fresh session should know about

- [`.agents/SETUP.md`](.agents/SETUP.md) — this file, the canonical runbook.
- [`scripts/swarm.sh`](scripts/swarm.sh) — start/stop/attach/status/nuke for the 8-agent swarm.
- [`scripts/c7_bootstrap.sh`](scripts/c7_bootstrap.sh) — full pod-side setup, idempotent. Run from c7 if anything got wiped.
- [`scripts/c7_sync_github.sh`](scripts/c7_sync_github.sh) — pod master → c7 → GitHub fork. Cron-managed (every 15min).
- [`scripts/c7_auth_check.sh`](scripts/c7_auth_check.sh) — Slack alerter for kubectl auth expiry. Cron-managed (every 30min).
- [`program.md`](program.md) — the autoresearch operating instructions the agents follow.
- [`train.py`](train.py) — the file the agents iterate on. Master starts at commit `08bb702` (FA2 baseline). c7-side scripts added on `ae869bc`.

### Don't do these without asking

- Do **not** run `swarm.sh nuke` — it deletes the agents' git history.
- Do **not** modify [`prepare.py`](prepare.py) — it's the read-only data/eval harness.
- Do **not** rerun `c7_bootstrap.sh` with `FORCE=1` — it'll re-stage the data and could nuke uncommitted agent state. The bootstrap is idempotent without FORCE.
- Do **not** push agents' branches (`autoresearch/<tag>-gpu*`) to GitHub — they're scratch experimental state with hundreds of force-pushes/day. The sync only ever pushes `master`.
- Do **not** edit [`train.py`](train.py) on master from c7 — agents would diverge. If you really want to seed a new baseline, stop the swarm with `swarm.sh stop`, edit, sync, then `swarm.sh up` to refork worktrees.

---

## Sync flow: pod ↔ c7 ↔ GitHub fork

**Single direction for `master`:** pod → c7 → `github.com/shuaitang5/autoresearch`.
**Agent branches** (`autoresearch/<tag>-gpu0..7`) **never leave FSx.**

```
                  every 15min cron
   pod master ──[git bundle]──→ c7 master ──[git push]──→ origin master (fork)
   (FSx)                        (~/autoresearch)            (GitHub)
                                  ▲
                                  │ if you edit scripts/ etc., commit + push from c7
                                  │ then run scripts/c7_sync_github.sh manually
                                  │ to also propagate the c7 commit back to the pod
```

### Where to make edits

- **Scripts/docs** (`scripts/`, `.agents/SETUP.md`): edit on c7 with vim/nano, commit, push to fork. Then run the script below to propagate to pod.
- **`train.py` baseline**: don't edit on master. Agents iterate it on per-gpu branches.
- **The agents themselves** edit `train.py` on their own branches — those changes never reach master.

### Commands

```bash
# Show 3-way state (pod / c7 / origin SHAs)
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com '
  bash ~/autoresearch/scripts/c7_sync_github.sh --status
'

# Manual one-shot sync (pod -> c7 -> fork)
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com '
  bash ~/autoresearch/scripts/c7_sync_github.sh
'

# Cron management
ssh c7 'bash ~/autoresearch/scripts/c7_sync_github.sh --install-cron'
ssh c7 'bash ~/autoresearch/scripts/c7_sync_github.sh --uninstall-cron'
```

### When you need to push a c7 commit back to the pod

The default sync flow is one-way (pod → c7 → fork). If you make a commit on c7 (e.g. updating a script), the cron will push it to the fork. To also propagate it to the pod's master:

```bash
# From c7
cd ~/autoresearch
git push origin master                                  # to fork (safe, fast-forward)

# Bundle + ship to pod
git bundle create /tmp/c7-delta.bundle <pod-master>..master
kubectl cp /tmp/c7-delta.bundle tangshua-sleeper-bom-worker-0:/tmp/c7-delta.bundle
kubectl exec tangshua-sleeper-bom-worker-0 -- bash -c '
  cd /scratch/tangshua/autoresearch
  # if pod has untracked dupes of files we are adding, move them aside first:
  git fetch /tmp/c7-delta.bundle master:refs/remotes/c7/master
  git merge --ff-only refs/remotes/c7/master
  rm /tmp/c7-delta.bundle
'
rm /tmp/c7-delta.bundle
```

If `git merge --ff-only` complains about untracked files, move them out of the way first (the bundle has them as tracked, so this is harmless): `mkdir -p /tmp/pod-untracked && mv <conflict-paths> /tmp/pod-untracked/`.

### What the sync cron does

- Every 15 min, checks if pod's master SHA differs from c7's master SHA.
- If they differ AND c7 is an ancestor of pod (i.e. pod only added commits) → fast-forward c7, push to origin.
- If they have **diverged** (e.g. someone committed on c7 separately) → refuses to auto-merge, posts a Slack warning, leaves things alone for manual resolution.
- The full log is at `~/.cache/autoresearch-sync/sync.log` on c7.

### Verifying it's working

The first cron-driven sync runs at the next `:00`, `:15`, `:30`, or `:45`. To check:
```bash
ssh c7 'tail -20 ~/.cache/autoresearch-sync/sync.log'
ssh c7 'gh repo view shuaitang5/autoresearch --json url,defaultBranchRef'
```

Or just open https://github.com/shuaitang5/autoresearch in a browser — recent commits should show `c7-side swarm launcher...` (`ae869bc`) at the tip.

---

## (full setup runbook below — only relevant for first-time setup)

If you've already set this up once and just want to launch / resume, jump to [Launch](#launch).

---

## Hosts and roles

| Host | Role | Why |
|---|---|---|
| `tangshua-sleeper-bom-worker-0` (k8s pod) | Compute (8x B200) + persistent storage (FSx at `/scratch/tangshua/`) | Has GPUs, **no internet egress**. Cannot reach api.anthropic.com / pypi / huggingface. Pure executor. |
| `dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com` (alias `c7`) | Hosts the 8 `claude -p` agents + does all setup | Has internet + kubectl + claude CLI. Persistent — survives laptop closing. |
| Your laptop | `ssh c7` only | Everything runs on c7 in tmux. |

---

## Architecture

```
+---------+   ssh   +----------------------+   kubectl exec   +--------------+
| laptop  | ------> |          c7          | ---------------> | pod (8x B200)|
+---------+         +----------------------+                  +--------------+
                    | bootstrap on c7:     |                  |              |
                    |   - uv venv          |                  | /scratch/    |
                    |   - prepare.py       |                  |   tangshua/  |
                    |   - kubectl cp       |                  |   (FSx)      |
                    | runtime on c7:       |                  |              |
                    |   - 8 tmux sessions  |                  |   8 git      |
                    |   - claude -p (each) |                  |   worktrees  |
                    |   - cron auth-check  |                  |              |
                    +----------+-----------+                  +--------------+
                               |
                               | api.anthropic.com (egress)
                               v
                          [Claude API]
```

c7 hosts the agents. The pod hosts the GPUs. The laptop is out of the picture once setup is done.

Why c7? It has internet + kubectl access + persistence + already has `claude` and `kraken` via the toolbox.

---

## One-time setup (on c7)

### 0. ssh in and clone the repo

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com    # or `c7` if you have the alias on laptop
mkdir -p ~/autoresearch
cd ~/autoresearch
# pull this repo (the one with scripts/) onto c7 — adjust source as needed:
git clone <your-fork-or-source> .
# OR just copy scripts/ + program.md from the upstream repo + your fork
```

### 1. Toolbox-managed CLIs (one-time)

```bash
# On c7 — install the Amazon-internal toolbox CLIs if missing
toolbox install midway
toolbox install kraken
toolbox install claude-code
export PATH=~/.toolbox/bin:$PATH

# Verify
mwinit --version 2>&1 | head -1
kraken --version
claude --version
```

Add `export PATH=~/.toolbox/bin:$PATH` to your `~/.bashrc` so cron + tmux pick it up.

### 2. Bootstrap (downloads deps, ships to pod, smoke-tests)

```bash
cd ~/autoresearch
bash scripts/c7_bootstrap.sh
```

What this does — see comments in [scripts/c7_bootstrap.sh](../scripts/c7_bootstrap.sh):

1. Installs `uv` to `~/.local/bin` if missing.
2. Creates a Python 3.10 venv at `~/autoresearch/.venv` via `uv` (c7's system Python is 3.7, too old).
3. Refreshes midway + kraken kubectl creds.
4. Verifies the pod is reachable (8x B200, sm_100, FSx mounted).
5. Stages the autoresearch repo onto the pod's FSx at `/scratch/tangshua/autoresearch/`.
6. Downloads `rustbpe` + `kernels==0.11.7` wheels (linux/cpython310), ships them to the pod, installs to `/scratch/tangshua/autoresearch/site/`.
7. Runs `prepare.py` on c7 (downloads HF data + trains the BPE tokenizer), ships to `/scratch/tangshua/.cache/autoresearch/`.
8. Patches `train.py` on the pod with the FA3→FA2 swap (B200 baseline) and commits.
9. Smoke-tests `train.py` on GPU 0 (~6 min wall).

Idempotent. Re-run any time. Skip steps with `SKIP_PREPARE=1 bash scripts/c7_bootstrap.sh` (skip data download) or `SKIP_SMOKE=1` (skip the 5-min smoke). Force-redo with `FORCE=1`.

Expected smoke-test output:
```
val_bpb:          0.978060
training_seconds: 300.3
peak_vram_mb:     45012.5
mfu_percent:      53.37
num_steps:        1275
```

### 3. Set up cred-expiry alerts (Slack)

```bash
# Create a Slack incoming webhook in your workspace; copy the URL.
# Then on c7:
mkdir -p ~/.config/autoresearch
cat > ~/.config/autoresearch/secrets.env <<EOF
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/XXX/YYY/ZZZ
EOF
chmod 600 ~/.config/autoresearch/secrets.env

# Test
bash scripts/c7_auth_check.sh --test-alert    # should post a message to Slack

# Install cron (every 30 min, alerts on kubectl-auth failure with 1h cooldown)
bash scripts/c7_auth_check.sh --install-cron
crontab -l | grep autoresearch                # verify
```

When kubectl auth dies, you get one Slack message with the exact fix command. See [scripts/c7_auth_check.sh](../scripts/c7_auth_check.sh).

To remove later: `bash scripts/c7_auth_check.sh --uninstall-cron`.

### 4. Launch the swarm

See [Launch](#launch) below.

---

## Launch

```bash
# On c7
cd ~/autoresearch
bash scripts/swarm.sh up
```

This:
1. Verifies pod has the repo + `site/` + data cache (run `c7_bootstrap.sh` first if not).
2. Creates 8 git worktrees on the pod's FSx: `/scratch/tangshua/autoresearch-gpu0..gpu7`, each on its own branch `autoresearch/<tag>-gpu<i>` (tag = today's `mmmdd`, e.g. `may19`).
3. Each worktree gets its own `results.tsv`.
4. Launches 8 tmux sessions on c7 (`ar-gpu0` .. `ar-gpu7`). Each runs `claude -p` headlessly with a kickoff prompt that includes:
   - The branch + worktree it owns
   - The shell prefix `kubectl exec <pod> -- bash -lc "cd <worktree> && <env exports> && <cmd>"`
   - Required env: `PYTHONPATH=/scratch/tangshua/autoresearch/site`, `HOME=/scratch/tangshua`, `HF_HUB_OFFLINE=1`, `CUDA_VISIBLE_DEVICES=<i>`, `PYTORCH_ALLOC_CONF=expandable_segments:True`
   - Modifications to program.md: skip "create branch", skip "ask for confirmation", "MFU is H100-scaled, ignore absolute", "loop forever".
5. Each agent's runner is a `while true` loop — if `claude -p` exits, it restarts with a "resume" prompt.

Closing your laptop does not affect this — the tmux sessions are on c7.

---

## Monitoring

All from c7:

```bash
# Quick health: one line per gpu
bash ~/autoresearch/scripts/swarm.sh status

# Deep dive on one agent
bash ~/autoresearch/scripts/swarm.sh attach 0       # tmux attach to gpu0 (Ctrl-B D to detach)
bash ~/autoresearch/scripts/swarm.sh logs 0         # tail the runner log (claude's stdout)
bash ~/autoresearch/scripts/swarm.sh podlog 0       # tail gpu0's most recent train.py run.log on the pod
```

Research progress (val_bpb numbers across all 8 agents):

```bash
for i in 0 1 2 3 4 5 6 7; do
  echo "=== gpu$i ==="
  kubectl exec tangshua-sleeper-bom-worker-0 -- bash -c "
    cd /scratch/tangshua/autoresearch-gpu$i
    git log --oneline -10
    echo '---'
    tail -10 results.tsv
  "
done
```

Stopping:

```bash
bash ~/autoresearch/scripts/swarm.sh stop          # kill tmux sessions; worktrees + branches stay
bash ~/autoresearch/scripts/swarm.sh nuke          # also delete worktrees + branches (destructive!)
```

---

## Resume after a break

After c7 reboot or kraken creds expire:

```bash
ssh dev-dsk-tangshua-2b-183a66f8.us-west-2.amazon.com
export PATH=~/.toolbox/bin:$PATH

mwinit
kraken jobs update-kubeconfig -p obsidian -j tangshua-sleeper-bom

tmux ls | grep ar-gpu                              # are agents still running?

# If they died, relaunch (worktrees + branches persist on FSx):
SKIP_WORKTREES=1 bash ~/autoresearch/scripts/swarm.sh up
```

---

## What survives what

| Event | Tmux sessions | Worktrees + branches | results.tsv | Data cache | Wheels |
|---|---|---|---|---|---|
| Laptop closes | ✅ survives | ✅ | ✅ | ✅ | ✅ |
| Laptop reboots | ✅ | ✅ | ✅ | ✅ | ✅ |
| ssh disconnect | ✅ | ✅ | ✅ | ✅ | ✅ |
| kraken creds expire | ❌ stalls (Slack alert fires; refresh + relaunch) | ✅ | ✅ | ✅ | ✅ |
| c7 reboots | ❌ killed | ✅ on FSx | ✅ on FSx | ✅ on FSx | ✅ on FSx |
| Pod reboots | ❌ killed | ✅ on FSx | ✅ on FSx | ✅ on FSx | ✅ on FSx |
| `swarm.sh stop` | ❌ killed | ✅ | ✅ | ✅ | ✅ |
| `swarm.sh nuke` | ❌ killed | ❌ deleted | ❌ deleted | ✅ | ✅ |

---

## Troubleshooting

### `the server has asked for the client to provide credentials`
kubectl creds expired. On c7:
```bash
mwinit
kraken jobs update-kubeconfig -p obsidian -j tangshua-sleeper-bom
```
The Slack alert (if configured) fires automatically when this happens.

### `Parquet magic bytes not found in footer`
Stale `._*` AppleDouble files (only happens if you ever shipped the data cache from macOS).
```bash
kubectl exec tangshua-sleeper-bom-worker-0 -- bash -c '
  find /scratch/tangshua/.cache/autoresearch -name "._*" -delete
'
```

### `ModuleNotFoundError: No module named 'rustbpe'`
PYTHONPATH isn't pointing at the FSx site dir. The agent's runner script sets this — but if the agent has decided to override env, check `train.py`'s actual invocation. The fix is `export PYTHONPATH=/scratch/tangshua/autoresearch/site`.

### `no kernel image is available for execution on the device`
Trying to use FA3 on B200 (Blackwell). Make sure the FA2 patch is applied (`grep _FA2Shim train.py` should match). The agent might have reverted it — check the worktree's `train.py`.

### Agent's `claude -p` exits and respawns repeatedly with no progress
The runner sleeps 30s between restarts. If you see >3 fast restarts, attach and inspect (`scripts/swarm.sh attach <i>`). Common cause: rate-limit, OOM loop, or the prompt is asking for confirmation that the agent thinks it shouldn't ignore.

### "Agent has been on experiment 1 for 2 hours"
Single train.py runs should be ~5 min. If longer, OOM-thrashing. Check `kubectl exec ... nvidia-smi`. The agent may have made an unfortunate combination — attach and intervene.

### Cross-pollination not happening
By design, in v0. Each agent only sees its own branch + results.tsv. To enable cross-pollination, edit `program.md` to (a) point at a shared `/scratch/tangshua/autoresearch/results.tsv` that all agents append to, and (b) periodically diff against the best-val_bpb sibling branch. Karpathy left this as future work.

---

## File map

```
c7 (cloud desktop):
  ~/.local/bin/uv                   uv binary
  ~/.toolbox/bin/{claude,kraken,mwinit}   Amazon-internal CLIs
  ~/.midway/cookie                  midway auth cookie
  ~/.kube/config                    kubectl context
  ~/.config/autoresearch/secrets.env  SLACK_WEBHOOK_URL (chmod 600)
  ~/.cache/autoresearch-auth/probe.log  cron auth-probe log
  ~/autoresearch/                   this repo's checkout on c7
  ~/autoresearch/.venv/             python 3.10 venv (uv)
  ~/autoresearch/scripts/           c7_bootstrap.sh, c7_auth_check.sh, swarm.sh
  ~/.autoresearch-stage/            staging dir for prepare.py output (one-time)
  ~/.autoresearch-swarm-logs/       per-agent runner logs + runner shell scripts

pod (tangshua-sleeper-bom-worker-0, /scratch/tangshua is FSx):
  /scratch/tangshua/autoresearch/             master branch (the "trunk")
  /scratch/tangshua/autoresearch-gpu{0..7}/   per-agent git worktrees
  /scratch/tangshua/autoresearch/wheels/      offline-installable wheels (kept for reinstalls)
  /scratch/tangshua/autoresearch/site/        rustbpe + kernels installed (PYTHONPATH target)
  /scratch/tangshua/.cache/autoresearch/      data shards + tokenizer (HOME-relative)
```

---

## Status as of 2026-05-19

- ✅ Pod has repo, .git, FSx-installed deps (`rustbpe`, `kernels==0.11.7` at `/scratch/tangshua/autoresearch/site`).
- ✅ Data shards (10 train + 1 val) + tokenizer at `/scratch/tangshua/.cache/autoresearch/`.
- ✅ `train.py` on pod is patched with the FA2 swap (working tree dirty on master — `c7_bootstrap.sh` will commit it on first run from c7).
- ✅ Smoke test passed: val_bpb=0.978060, 300s training, 53.37% MFU (H100-scaled), 45GB VRAM, 1275 steps.
- ✅ `scripts/{c7_bootstrap.sh, c7_auth_check.sh, swarm.sh}` written.
- ⏳ Not yet executed on c7. Next step: ssh c7, clone this repo, run `bash scripts/c7_bootstrap.sh` then `bash scripts/swarm.sh up`.

---

## Why this design

Read [program.md](../program.md) first — autoresearch is intentionally minimal: 3 files, no orchestrator, no judge. The "intelligence" is the agent reading its own `results.tsv` to plan the next experiment. Don't over-engineer.

The choice to host agents on c7:
- Pod has GPUs but no internet → can't run `claude -p` (needs api.anthropic.com).
- Laptop has internet but sleeps when you go home → agents die.
- c7 has both internet and persistence + already has `claude` and `kraken` via the toolbox.

The choice to skip `uv sync` on the pod:
- Pod is air-gapped — `uv sync` would fail on PyPI fetch.
- Pod has torch 2.7.0a0+cu129 + flash_attn 2.7.3 + pyarrow + transformer-engine pre-installed, all working on B200.
- Re-shipping a pinned-by-pyproject torch 2.9.1 wheel to the pod is unnecessary churn.

The choice to use FA2 (not FA3 or FA4) baseline:
- FA3 is Hopper-only — fails on B200 with "no kernel image available".
- FA4 (kernels-community/flash-attn4) is Blackwell-aware but uses cute-DSL via `nvidia-cutlass-dsl-libs-base`, which isn't on public PyPI (split-wheel issue introduced in 4.4).
- Pod has FA2 (`flash_attn 2.7.3`) with working sm_100 kernels. Same `flash_attn_func` API. Smoke test confirms 53% MFU.
- The agent can later try TE attention (`amzn-agi-3p-transformer-engine 2.4.105` is installed) or build FA4 from source if it wants.
