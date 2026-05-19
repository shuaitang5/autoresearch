#!/usr/bin/env bash
#
# Probes whether c7 -> pod kubectl access still works. Posts to Slack on failure.
# Designed for cron — quiet on success, alerts only when broken.
#
# Setup:
#   1. Put your Slack webhook URL in ~/.config/autoresearch/secrets.env:
#      mkdir -p ~/.config/autoresearch
#      cat > ~/.config/autoresearch/secrets.env <<EOF
#      SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
#      EOF
#      chmod 600 ~/.config/autoresearch/secrets.env
#   2. Install the cron entry:  bash scripts/c7_auth_check.sh --install-cron
#
# Usage:
#   scripts/c7_auth_check.sh                # one probe; alerts on failure
#   scripts/c7_auth_check.sh --install-cron # writes a crontab entry, every 30 min
#   scripts/c7_auth_check.sh --uninstall-cron
#   scripts/c7_auth_check.sh --test-alert   # send a test Slack message regardless
#
# Env overrides:
#   POD=tangshua-sleeper-bom-worker-0
#   ALERT_COOLDOWN_SEC=3600                 # don't re-alert more than once per hour for the same failure
#   STATE_DIR=~/.cache/autoresearch-auth

set -uo pipefail

POD="${POD:-tangshua-sleeper-bom-worker-0}"
SECRETS_FILE="${SECRETS_FILE:-$HOME/.config/autoresearch/secrets.env}"
STATE_DIR="${STATE_DIR:-$HOME/.cache/autoresearch-auth}"
LOG_FILE="$STATE_DIR/probe.log"
LAST_ALERT_FILE="$STATE_DIR/last_alert"
ALERT_COOLDOWN_SEC="${ALERT_COOLDOWN_SEC:-3600}"

mkdir -p "$STATE_DIR"

ts() { date -u +%FT%TZ; }
log() { printf "%s %s\n" "$(ts)" "$*" >> "$LOG_FILE"; }

load_secrets() {
  if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SECRETS_FILE"
  fi
}

post_slack() {
  local msg="$1"
  load_secrets
  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    log "SLACK_WEBHOOK_URL not set ($SECRETS_FILE missing or empty); skipping Slack post"
    return 1
  fi
  local payload
  payload=$(printf '{"text": %s}' "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")
  if curl -fsS -X POST -H 'Content-Type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1; then
    log "slack ok"
    return 0
  else
    log "slack post FAILED"
    return 1
  fi
}

cooldown_active() {
  [[ -f "$LAST_ALERT_FILE" ]] || return 1
  local last age
  last=$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)
  age=$(( $(date +%s) - last ))
  (( age < ALERT_COOLDOWN_SEC ))
}

mark_alert_sent() {
  date +%s > "$LAST_ALERT_FILE"
}

probe() {
  local err
  err=$(kubectl exec "$POD" -- true 2>&1)
  local rc=$?
  if (( rc == 0 )); then
    return 0
  fi
  printf '%s\n' "$err"
  return $rc
}

cmd_probe() {
  if probe >/dev/null 2>&1; then
    log "probe OK"
    return 0
  fi
  local err
  err=$(probe 2>&1 || true)
  log "probe FAILED: $err"

  if cooldown_active; then
    log "alert in cooldown ($ALERT_COOLDOWN_SEC s), skipping Slack"
    return 1
  fi

  local hostname
  hostname=$(hostname)
  local msg
  msg=$(cat <<EOF
:rotating_light: autoresearch swarm: kubectl auth on c7 needs refresh

host: $hostname
pod:  $POD
time: $(ts)
err:  $err

Fix:
  ssh $hostname
  export PATH=~/.toolbox/bin:\$PATH
  mwinit
  kraken jobs update-kubeconfig -p obsidian -j ${KRAKEN_JOB:-${POD%-worker-*}}
EOF
)
  if post_slack "$msg"; then
    mark_alert_sent
  fi
  return 1
}

cmd_test_alert() {
  local msg=":white_check_mark: autoresearch swarm: c7_auth_check.sh test alert from $(hostname) at $(ts). Slack delivery is working."
  post_slack "$msg" && echo "test alert sent"
}

cmd_install_cron() {
  local self
  self=$(realpath "$0")
  local entry="*/30 * * * * $self >> $LOG_FILE 2>&1"
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
  --test-alert)     cmd_test_alert ;;
  "")               cmd_probe ;;
  *)                echo "unknown flag: $1" >&2; exit 2 ;;
esac
