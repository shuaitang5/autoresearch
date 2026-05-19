#!/usr/bin/env bash
#
# Sync the swarm's master branch from the pod to a GitHub fork. Runs on c7.
#
# Flow (master only — agent branches stay on FSx):
#
#   pod /scratch/tangshua/autoresearch (master)
#       │  rsync via kubectl
#       ▼
#   c7 ~/autoresearch (master)
#       │  git push
#       ▼
#   GitHub fork (e.g. github.com/<you>/autoresearch)
#
# c7 ↔ pod: only `master`. Agent branches `autoresearch/<tag>-gpu*` are scratch state
# on FSx, never pushed.
#
# Usage:
#   scripts/c7_sync_github.sh                      # pull pod master, push to GitHub
#   scripts/c7_sync_github.sh --install-cron       # every 15 min
#   scripts/c7_sync_github.sh --uninstall-cron
#   scripts/c7_sync_github.sh --status             # show divergence c7 vs pod vs origin
#
# Env (defaults):
#   POD=tangshua-sleeper-bom-worker-0
#   POD_REPO=/scratch/tangshua/autoresearch
#   C7_REPO=$HOME/autoresearch
#   GH_REMOTE=origin                                # what to push to (set up via gh repo set-default)
#   STATE_DIR=$HOME/.cache/autoresearch-sync

set -uo pipefail

POD="${POD:-tangshua-sleeper-bom-worker-0}"
POD_REPO="${POD_REPO:-/scratch/tangshua/autoresearch}"
C7_REPO="${C7_REPO:-$HOME/autoresearch}"
GH_REMOTE="${GH_REMOTE:-origin}"
STATE_DIR="${STATE_DIR:-$HOME/.cache/autoresearch-sync}"
LOG_FILE="$STATE_DIR/sync.log"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.config/autoresearch/secrets.env}"

# PATH for cron / non-interactive shells
case ":$PATH:" in *":$HOME/.toolbox/bin:"*) ;; *) export PATH="$HOME/.toolbox/bin:$PATH" ;; esac
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac

mkdir -p "$STATE_DIR"

ts() { date -u +%FT%TZ; }
log() { printf "%s %s\n" "$(ts)" "$*" | tee -a "$LOG_FILE" >&2; }
die() { log "ERROR: $*"; exit 1; }
silent_log() { printf "%s %s\n" "$(ts)" "$*" >> "$LOG_FILE"; }

post_slack_if_configured() {
  local msg="$1"
  [[ -f "$SECRETS_FILE" ]] || return 0
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  [[ -n "${SLACK_WEBHOOK_URL:-}" ]] || return 0
  local payload
  payload=$(printf '{"text": %s}' "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  curl -fsS -X POST -H 'Content-Type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# Get the SHA of master on the pod (via kubectl).
pod_master_sha() {
  kubectl exec "$POD" -- bash -c "cd $POD_REPO && git rev-parse master" 2>/dev/null
}

# Get the SHA of master on c7.
c7_master_sha() {
  git -C "$C7_REPO" rev-parse master 2>/dev/null
}

# Get the SHA of master on GitHub (origin/master).
origin_master_sha() {
  git -C "$C7_REPO" rev-parse "$GH_REMOTE/master" 2>/dev/null
}

cmd_status() {
  echo "pod    master = $(pod_master_sha 2>&1)"
  echo "c7     master = $(c7_master_sha 2>&1)"
  echo "origin master = $(origin_master_sha 2>&1)"
  echo
  echo "c7 git status:"
  git -C "$C7_REPO" status --short --branch 2>&1 | head -10
}

# Pull pod master into c7's working tree.
# Strategy: rsync the *files* (not .git) from pod to a temp location, then
# bring c7's repo to match via fetch-from-pod and merge. Simpler approach:
# bundle the pod's master ref out via `git bundle` and import into c7.
sync_pod_to_c7() {
  local pod_sha c7_sha
  pod_sha=$(pod_master_sha) || die "can't read pod master sha"
  c7_sha=$(c7_master_sha) || die "can't read c7 master sha"

  if [[ "$pod_sha" == "$c7_sha" ]]; then
    silent_log "pod==c7 master ($pod_sha), nothing to pull"
    return 0
  fi

  # Check that c7 is an ancestor of pod (i.e. pod has only added commits).
  # If not, pod has diverged — bail noisily so user investigates.
  if [[ -n "$c7_sha" ]] && ! kubectl exec "$POD" -- bash -c "cd $POD_REPO && git merge-base --is-ancestor $c7_sha master" 2>/dev/null; then
    log "DIVERGED: c7 master ($c7_sha) is not an ancestor of pod master ($pod_sha)"
    log "  refusing to auto-sync; resolve manually"
    post_slack_if_configured ":warning: autoresearch sync: pod and c7 master diverged. Manual fix needed on c7. See $LOG_FILE"
    return 2
  fi

  log "pulling pod master ($pod_sha) into c7..."
  # Bundle commits we don't have, ship to c7, fetch into a remote, fast-forward master.
  local bundle="/tmp/ar-pod-master-$$.bundle"
  local revs
  if [[ -z "$c7_sha" ]]; then
    revs="master"
  else
    revs="${c7_sha}..master"
  fi
  kubectl exec "$POD" -- bash -c "cd $POD_REPO && git bundle create /tmp/ar-master.bundle $revs && cat /tmp/ar-master.bundle" > "$bundle" 2>/dev/null \
    || die "git bundle create on pod failed"
  kubectl exec "$POD" -- bash -c "rm -f /tmp/ar-master.bundle" >/dev/null 2>&1 || true

  ( cd "$C7_REPO"
    git fetch "$bundle" master:refs/remotes/pod/master 2>&1 | tail -5
    # fast-forward master if checked out, else update the ref
    local cur
    cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ "$cur" == "master" ]]; then
      git merge --ff-only refs/remotes/pod/master 2>&1 | tail -3 || die "ff-only merge failed (working tree dirty?)"
    else
      git update-ref refs/heads/master refs/remotes/pod/master
    fi
  ) || { rm -f "$bundle"; return 1; }
  rm -f "$bundle"
  log "c7 master now at $(c7_master_sha)"
}

# Push c7's master to the GitHub remote.
sync_c7_to_origin() {
  local c7_sha origin_sha
  c7_sha=$(c7_master_sha) || die "c7 has no master"
  origin_sha=$(origin_master_sha 2>/dev/null || echo "")

  if [[ "$c7_sha" == "$origin_sha" ]]; then
    silent_log "c7==origin master ($c7_sha), nothing to push"
    return 0
  fi

  log "pushing c7 master ($c7_sha) to $GH_REMOTE..."
  if ! ( cd "$C7_REPO" && git push "$GH_REMOTE" master 2>&1 | tail -5 ); then
    log "PUSH FAILED to $GH_REMOTE"
    post_slack_if_configured ":x: autoresearch sync: \`git push $GH_REMOTE master\` failed on c7. See $LOG_FILE"
    return 1
  fi
  log "pushed; origin master = $(origin_master_sha)"
}

cmd_sync() {
  cd "$C7_REPO" 2>/dev/null || die "C7_REPO=$C7_REPO doesn't exist"
  git -C "$C7_REPO" remote get-url "$GH_REMOTE" >/dev/null 2>&1 \
    || die "no remote '$GH_REMOTE' on c7 repo. Run: git -C $C7_REPO remote add $GH_REMOTE <url>"

  # quick fetch to know what origin already has
  ( cd "$C7_REPO" && git fetch --quiet "$GH_REMOTE" master 2>/dev/null ) || true

  sync_pod_to_c7 || return $?
  sync_c7_to_origin || return $?
}

cmd_install_cron() {
  local self
  self=$(realpath "$0")
  local entry="*/15 * * * * $self >> $LOG_FILE 2>&1"
  local existing
  existing=$(crontab -l 2>/dev/null || true)
  if grep -qF "$self" <<< "$existing"; then
    echo "cron entry already present:"
    grep -F "$self" <<< "$existing"
    return 0
  fi
  ( printf '%s\n' "$existing"; printf '%s\n' "$entry" ) | crontab -
  echo "installed cron: $entry"
  echo "log: $LOG_FILE"
}

cmd_uninstall_cron() {
  local self
  self=$(realpath "$0")
  local existing
  existing=$(crontab -l 2>/dev/null || true)
  if ! grep -qF "$self" <<< "$existing"; then
    echo "no cron entry found"
    return 0
  fi
  grep -vF "$self" <<< "$existing" | crontab -
  echo "removed cron entry"
}

case "${1:-}" in
  --install-cron)   cmd_install_cron ;;
  --uninstall-cron) cmd_uninstall_cron ;;
  --status)         cmd_status ;;
  "")               cmd_sync ;;
  *)                echo "unknown flag: $1" >&2; exit 2 ;;
esac
