#!/usr/bin/env bash
#
# Fetches per-agent results.tsv + git log from the pod's FSx into local dirs,
# ready for plot_swarm.py.
#
# On c7: dumps to /tmp/swarm_results and /tmp/swarm_gitlog.
# Run from anywhere with kubectl access to the pod.

set -euo pipefail

POD="${POD:-tangshua-sleeper-bom-worker-0}"
POD_REPO_BASE="${POD_REPO_BASE:-/scratch/tangshua}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/swarm_results}"
GITLOG_DIR="${GITLOG_DIR:-/tmp/swarm_gitlog}"
NUM_GPUS="${NUM_GPUS:-8}"

# Ensure toolbox/uv binaries are on PATH (cron / non-interactive shells)
case ":$PATH:" in *":$HOME/.toolbox/bin:"*) ;; *) export PATH="$HOME/.toolbox/bin:$PATH" ;; esac
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

mkdir -p "$RESULTS_DIR" "$GITLOG_DIR"

for i in $(seq 0 $((NUM_GPUS - 1))); do
  worktree="$POD_REPO_BASE/autoresearch-gpu$i"
  # results.tsv (every experiment, kept + discarded + crash)
  kubectl exec "$POD" -- cat "$worktree/results.tsv" \
    > "$RESULTS_DIR/results_gpu$i.tsv" 2>/dev/null \
    || echo "warn: could not read $worktree/results.tsv" >&2

  # git log master..HEAD (canonical kept-commit list; survives results.tsv wipes)
  kubectl exec "$POD" -- bash -c "cd $worktree && git log master..HEAD --reverse --pretty=format:%h%x09%s" \
    > "$GITLOG_DIR/gpu$i.tsv" 2>/dev/null \
    || echo "warn: could not git log $worktree" >&2

  printf "gpu%d: results=%d rows  gitlog=%d commits\n" \
    "$i" \
    "$(wc -l < "$RESULTS_DIR/results_gpu$i.tsv" 2>/dev/null || echo 0)" \
    "$(wc -l < "$GITLOG_DIR/gpu$i.tsv" 2>/dev/null || echo 0)"
done
