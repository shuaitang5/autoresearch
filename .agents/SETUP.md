# autoresearch swarm: c7-only runbook

Run [karpathy/autoresearch](https://github.com/karpathy/autoresearch) as an **8-agent swarm** on a Leviathan B200 sleeper pod. **Everything happens on `c7` cloud desktop.** Your laptop is only used to ssh into c7.

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
kraken jobs update-kubeconfig -p obsidian -j tangshua-sleeper-bom-worker-0

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
kraken jobs update-kubeconfig -p obsidian -j tangshua-sleeper-bom-worker-0
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
