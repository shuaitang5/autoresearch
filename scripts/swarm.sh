#!/usr/bin/env bash
#
# autoresearch swarm launcher (c7 cloud-desktop edition).
#
# Topology:
#   - This script runs on a Linux host that has BOTH:
#       (a) `claude` CLI with internet egress to api.anthropic.com
#       (b) `kubectl` access to the GPU pod (via kraken auth)
#   - It launches 8 headless `claude -p` agents in tmux sessions, each pinned
#     to a different GPU on the remote pod via kubectl exec + CUDA_VISIBLE_DEVICES.
#   - Each agent operates in a per-GPU git worktree on the pod's FSx, on its
#     own branch, and runs the experiment loop from program.md.
#
# Usage:
#   scripts/swarm.sh up           # create worktrees + launch agents
#   scripts/swarm.sh status       # list sessions
#   scripts/swarm.sh attach N     # tmux attach to gpu N's session
#   scripts/swarm.sh logs N       # tail gpu N's runner log (laptop side)
#   scripts/swarm.sh podlog N     # tail gpu N's last train.py run.log on the pod
#   scripts/swarm.sh stop         # kill all sessions (worktrees stay)
#   scripts/swarm.sh nuke         # stop + remove worktrees + delete branches
#
# Env overrides:
#   GPUS=8
#   TAG=may19                     # default: today's lowercase month+day
#   POD=tangshua-sleeper-bom-worker-0
#   POD_REPO=/scratch/tangshua/autoresearch
#   POD_CACHE=/scratch/tangshua/.cache
#   POD_SITE=$POD_REPO/site
#   CLAUDE_MODEL=opus
#   SKIP_WORKTREES=1              # if worktrees already created

set -euo pipefail

# Ensure toolbox + uv-installed binaries are findable regardless of how this is invoked
# (ssh non-interactive, cron, etc.).
case ":$PATH:" in *":$HOME/.toolbox/bin:"*) ;; *) export PATH="$HOME/.toolbox/bin:$PATH" ;; esac
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

# c7's /usr/bin/tmux is 1.8 (2018) and is buggy on AL2 — `new-session -d` exits 1.
# Apollo ships a modern tmux (3.6a) at /apollo/env/envImprovement/bin/tmux. Prefer it.
TMUX_BIN="${TMUX_BIN:-}"
if [[ -z "$TMUX_BIN" ]]; then
  if [[ -x /apollo/env/envImprovement/bin/tmux ]]; then
    TMUX_BIN=/apollo/env/envImprovement/bin/tmux
  else
    TMUX_BIN=$(command -v tmux)
  fi
fi

GPUS="${GPUS:-8}"
TAG="${TAG:-$(date +%b%d | tr '[:upper:]' '[:lower:]')}"
POD="${POD:-tangshua-sleeper-bom-worker-0}"
POD_REPO="${POD_REPO:-/scratch/tangshua/autoresearch}"
POD_CACHE="${POD_CACHE:-/scratch/tangshua/.cache}"
POD_SITE="${POD_SITE:-$POD_REPO/site}"
CLAUDE_MODEL="${CLAUDE_MODEL:-opus}"
LOG_DIR="${LOG_DIR:-$HOME/.autoresearch-swarm-logs}"
SESSION_PREFIX="ar"

log() { printf "[swarm] %s\n" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

worktree_path_pod() { echo "$POD_REPO-gpu$1"; }
branch_name()       { echo "autoresearch/$TAG-gpu$1"; }
session_name()      { echo "$SESSION_PREFIX-gpu$1"; }
log_file()          { echo "$LOG_DIR/gpu$1.log"; }

kx() { kubectl exec "$POD" -- bash -lc "$@"; }
kx_quiet() { kubectl exec "$POD" -- bash -lc "$@" 2>&1; }

# ---- env that the pod side needs to source on every exec ----
# PYTHONPATH picks up rustbpe + kernels from the FSx-installed site dir.
# HF_HOME points at the pre-cached FA3 kernel snapshot.
# HF_HUB_OFFLINE prevents kernels from trying to network-fetch.
pod_env_export() {
  cat <<EOF
export PYTHONPATH=$POD_SITE:\${PYTHONPATH:-}
export HF_HOME=$POD_CACHE/huggingface
export HF_HUB_OFFLINE=1
export HF_HUB_DISABLE_PROGRESS_BARS=1
export PYTORCH_ALLOC_CONF=expandable_segments:True
EOF
}

cmd_up() {
  require kubectl; require claude
  [[ -x "$TMUX_BIN" ]] || die "no usable tmux at TMUX_BIN=$TMUX_BIN"
  kubectl get pod "$POD" >/dev/null 2>&1 || die "pod $POD not reachable; run: bash ~/prod11_bom_operator.sh"

  mkdir -p "$LOG_DIR"

  log "verifying pod has repo + deps..."
  kx 'test -d '"$POD_REPO"'/.git && test -f '"$POD_SITE"'/rustbpe/__init__.py && test -d '"$POD_CACHE"'/autoresearch/data' \
    || die "pod missing repo/site/cache; rerun .agents/SETUP.md staging steps"

  if [[ -z "${SKIP_WORKTREES:-}" ]]; then
    log "creating $GPUS git worktrees on pod ($POD_REPO-gpu0..$((GPUS-1)))..."
    for i in $(seq 0 $((GPUS - 1))); do
      local wt="$(worktree_path_pod "$i")"
      local br="$(branch_name "$i")"
      kx "
        set -e
        cd $POD_REPO
        if [ -d $wt ]; then echo '  gpu$i: $wt exists, skipping'; exit 0; fi
        if git rev-parse --verify $br >/dev/null 2>&1; then
          git worktree add $wt $br
        else
          git worktree add $wt -b $br
        fi
        # ensure git can commit inside the worktree
        cd $wt
        git config user.email tangshua-swarm@amazon.com
        git config user.name 'autoresearch-gpu$i'
        # initialize results.tsv per program.md
        printf 'commit\tval_bpb\tmemory_gb\tstatus\tdescription\n' > results.tsv
      " 2>&1 | sed "s/^/  gpu$i: /"
    done
  fi

  log "launching $GPUS agents in tmux on this host..."
  for i in $(seq 0 $((GPUS - 1))); do
    local wt sess logf br
    wt="$(worktree_path_pod "$i")"
    sess="$(session_name "$i")"
    logf="$(log_file "$i")"
    br="$(branch_name "$i")"

    if "$TMUX_BIN" has-session -t "$sess" 2>/dev/null; then
      log "  gpu$i: session $sess already running"
      continue
    fi

    # Per-agent runner script. claude -p exits when the model stops talking;
    # we relaunch in a loop with a "resume" prompt so the FOREVER loop survives.
    local runner="$LOG_DIR/run-gpu$i.sh"
    cat > "$runner" <<RUNNER_EOF
#!/usr/bin/env bash
set -u
# Ensure toolbox CLIs (claude, kraken, kubectl) are on PATH inside tmux/cron contexts.
export PATH="\$HOME/.toolbox/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
LOG="$logf"
GPU=$i
WT="$wt"
POD="$POD"
BR="$br"
TAG="$TAG"
MODEL="$CLAUDE_MODEL"

KICKOFF=\$(cat <<'PROMPT_EOF'
You are agent gpu$i in an 8-agent autoresearch swarm running on an 8x B200 pod.

IMPORTANT TOPOLOGY:
- You (this Claude session) run on the cloud desktop \`c7\`. The actual GPU lives
  on a remote k8s pod ($POD) that has NO INTERNET. You reach it via kubectl exec.
- Your working directory is a git worktree on the pod's FSx at: $wt
- All shell work happens via: kubectl exec $POD -- bash -lc "cd $wt && <cmd>"
- There is a prepared environment on the pod. Always source it before running python:
    export PYTHONPATH=$POD_SITE:\\\${PYTHONPATH:-}
    export HF_HOME=$POD_CACHE/huggingface
    export HF_HUB_OFFLINE=1
    export PYTORCH_ALLOC_CONF=expandable_segments:True
    export CUDA_VISIBLE_DEVICES=$i
- Run training as: kubectl exec $POD -- bash -lc "cd $wt && <env exports above> && python3 train.py > run.log 2>&1"
- DO NOT run \`uv\`, \`uv sync\`, \`pip install\`. The pod is offline. Deps are pre-installed at $POD_SITE.
- DO NOT run \`prepare.py\`. Data is pre-staged at $POD_CACHE/autoresearch.

Read program.md and follow it. Important deltas from program.md:
- Branch \`$br\` ALREADY EXISTS, you are already on it. Skip Setup step 2.
- Run tag is \`$TAG-gpu$i\`. Use it in commit messages.
- DO NOT pause to ask for confirmation. There is no human at the keyboard.
  Skip "Confirm and go". Set up, then immediately enter the experiment loop.
- The MFU printout in train.py assumes H100; you are on B200. Ignore the absolute MFU.
- ~/.cache/autoresearch/ is shared and populated; do NOT re-run prepare.py.
- results.tsv is per-worktree (untracked). Append your results.
- Loop forever per program.md. Never stop on your own.

Begin now.
PROMPT_EOF
)

RESUME=\$(cat <<'PROMPT_EOF'
You are agent gpu$i resuming an autoresearch run on branch $br, working in $wt
on remote pod $POD. All shell goes through: kubectl exec $POD -- bash -lc "cd $wt && ..."
With env: PYTHONPATH=$POD_SITE HF_HOME=$POD_CACHE/huggingface HF_HUB_OFFLINE=1 CUDA_VISIBLE_DEVICES=$i.
Read program.md, then check results.tsv and \`git log\` to see where you left off.
Continue the experiment loop forever. Do not re-run setup, do not create new branches.
PROMPT_EOF
)

iter=0
while true; do
  if [[ \$iter -eq 0 ]]; then
    PROMPT="\$KICKOFF"
  else
    PROMPT="\$RESUME"
  fi
  echo "[runner] === iter \$iter starting \$(date -u +%FT%TZ) ===" >> "\$LOG"
  claude -p "\$PROMPT" \\
    --model "\$MODEL" \\
    --dangerously-skip-permissions \\
    >> "\$LOG" 2>&1 || true
  echo "[runner] === iter \$iter ended \$(date -u +%FT%TZ); restarting in 30s ===" >> "\$LOG"
  iter=\$((iter + 1))
  sleep 30
done
RUNNER_EOF
    chmod +x "$runner"

    "$TMUX_BIN" new-session -d -s "$sess" "$runner"
    log "  gpu$i: tmux=$sess  log=$logf"
  done

  log "swarm is up."
  log "  scripts/swarm.sh status      # quick health"
  log "  scripts/swarm.sh attach 0    # attach to gpu0"
  log "  scripts/swarm.sh logs 0      # tail gpu0 runner log"
  log "  scripts/swarm.sh podlog 0    # tail gpu0's last train.py run.log on the pod"
}

cmd_status() {
  # Per-gpu: tmux state (instant), then research progress (one kubectl exec for all 8).

  # 1. tmux state (local, fast)
  local states=()
  for i in $(seq 0 $((GPUS - 1))); do
    if "$TMUX_BIN" has-session -t "$(session_name "$i")" 2>/dev/null; then
      states[$i]=RUN
    else
      states[$i]=DOWN
    fi
  done

  # 2. research progress per gpu — single kubectl exec, parsed locally
  local raw
  raw=$(kubectl exec "$POD" -- bash -c "
    for i in \$(seq 0 $((GPUS - 1))); do
      tsv=$POD_REPO-gpu\$i/results.tsv
      if [[ -f \$tsv ]]; then
        # Format: commit \t val_bpb \t memory_gb \t status \t description
        # Some agents wrote literal '\\t' instead of tab — handle both via sed normalize.
        # Print: gpu_idx | total | n_keep | n_discard | n_crash | best_val_bpb | last_val_bpb | last_status | last_desc
        sed 's/\\\\t/\t/g' \$tsv | awk -F'\t' -v gpu=\$i '
          NR==1 { next }                                  # skip header
          NF<4 { next }                                   # skip blank/malformed
          { total++ }
          \$4==\"keep\"    { keep++ }
          \$4==\"discard\" { disc++ }
          \$4==\"crash\"   { crash++ }
          \$4!=\"crash\" && (\$2+0)>0 && (best==\"\" || (\$2+0)<best) { best=\$2 }
          { last_bpb=\$2; last_status=\$4; last_desc=\$5 }
          END {
            if (total==0) { printf \"%d|0|0|0|0|-|-|-|-\n\", gpu }
            else { printf \"%d|%d|%d|%d|%d|%s|%s|%s|%s\n\", gpu, total, keep+0, disc+0, crash+0, best, last_bpb, last_status, last_desc }
          }
        '
      else
        echo \"\$i|0|0|0|0|-|-|-|(no results.tsv)\"
      fi
    done
  " 2>/dev/null)

  # 3. render — column widths sized for typical values
  #   GPU(4)  STATE(5)  EXP/K/D/C(13)  BEST_BPB(9)  LAST_BPB(9)  LAST_ST(8)  DESC(rest)
  local fmt="%-4s  %-5s  %-13s  %-9s  %-9s  %-8s  %s\n"
  printf "$fmt" GPU STATE TOT/K/D/C BEST_BPB LAST_BPB LAST_ST LAST_DESCRIPTION
  while IFS='|' read -r idx total keep disc crash best last_bpb last_st last_desc; do
    [[ -z "$idx" ]] && continue
    local kdc="${total}/${keep}/${disc}/${crash}"
    local desc_trunc="${last_desc:0:60}"
    printf "$fmt" "gpu$idx" "${states[$idx]}" "$kdc" "$best" "$last_bpb" "$last_st" "$desc_trunc"
  done <<< "$raw"
}

cmd_attach() { "$TMUX_BIN" attach -t "$(session_name "${1:?usage: attach <i>}")"; }
cmd_logs()   { tail -n 80 -f "$(log_file "${1:?usage: logs <i>}")"; }

cmd_podlog() {
  local i="${1:?usage: podlog <i>}"
  local wt="$(worktree_path_pod "$i")"
  kx "tail -n 80 $wt/run.log 2>/dev/null || echo '(no run.log yet on pod for gpu$i)'"
}

cmd_stop() {
  for i in $(seq 0 $((GPUS - 1))); do
    local sess="$(session_name "$i")"
    if "$TMUX_BIN" has-session -t "$sess" 2>/dev/null; then
      "$TMUX_BIN" kill-session -t "$sess"; log "killed $sess"
    fi
  done
}

cmd_nuke() {
  cmd_stop
  for i in $(seq 0 $((GPUS - 1))); do
    local wt br
    wt="$(worktree_path_pod "$i")"
    br="$(branch_name "$i")"
    kx "cd $POD_REPO && git worktree remove --force $wt 2>/dev/null; git branch -D $br 2>/dev/null; true" >/dev/null
  done
  log "nuked worktrees + branches for tag=$TAG"
}

case "${1:-up}" in
  up)     cmd_up ;;
  status) cmd_status ;;
  attach) shift; cmd_attach "$@" ;;
  logs)   shift; cmd_logs "$@" ;;
  podlog) shift; cmd_podlog "$@" ;;
  stop)   cmd_stop ;;
  nuke)   cmd_nuke ;;
  *)      die "unknown subcommand: $1" ;;
esac
