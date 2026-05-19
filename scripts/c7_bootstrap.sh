#!/usr/bin/env bash
#
# Bootstrap autoresearch from c7 (cloud desktop). Replaces every laptop-side
# step in .agents/SETUP.md. Run this once on c7. Idempotent — safe to re-run.
#
# What it does:
#   1. Installs `uv` to ~/.local/bin if missing (single-binary, no root).
#   2. Creates a Python 3.10 venv at ~/autoresearch/.venv via uv.
#   3. Refreshes midway + kraken kubectl creds.
#   4. Verifies the pod is reachable + has /scratch/tangshua/ FSx mounted.
#   5. Stages the autoresearch repo onto the pod's FSx.
#   6. Downloads rustbpe + kernels wheels (linux/cpython310) on c7, ships to pod, installs.
#   7. Runs prepare.py (downloads HF data + trains tokenizer) into a staging cache on c7.
#   8. Ships the data cache to the pod's FSx at /scratch/tangshua/.cache/autoresearch/.
#   9. Patches train.py with the FA2 swap (B200 baseline) and commits on the pod.
#   10. Smoke-tests train.py on GPU 0.
#
# After this finishes, run: bash scripts/swarm.sh up
#
# Env overrides (defaults shown):
#   POD=tangshua-sleeper-bom-worker-0
#   POD_FSX=/scratch/tangshua
#   NUM_SHARDS=10                # training shards to download
#   SKIP_PREPARE=1               # skip data download if cache already on pod
#   SKIP_SMOKE=1                 # skip the 5-min smoke run
#   FORCE=1                      # ignore "already done" markers and redo

set -euo pipefail

POD="${POD:-tangshua-sleeper-bom-worker-0}"
POD_FSX="${POD_FSX:-/scratch/tangshua}"
POD_REPO="$POD_FSX/autoresearch"
POD_SITE="$POD_REPO/site"
POD_CACHE="$POD_FSX/.cache/autoresearch"
NUM_SHARDS="${NUM_SHARDS:-10}"

# Source repo on c7 = the parent of where this script lives.
# That way `bash ~/autoresearch/scripts/c7_bootstrap.sh` ships ~/autoresearch.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_REPO="${LOCAL_REPO:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOCAL_VENV="$LOCAL_REPO/.venv"
LOCAL_STAGE="$HOME/.autoresearch-stage"
LOCAL_WHEELS="$LOCAL_STAGE/wheels"
LOCAL_DATA="$LOCAL_STAGE/.cache/autoresearch"

log() { printf "[bootstrap] %s\n" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

ensure_path() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) export PATH="$1:$PATH" ;;
  esac
}

# --- step 1: uv ---
ensure_uv() {
  ensure_path "$HOME/.local/bin"
  ensure_path "$HOME/.toolbox/bin"
  if have uv; then
    log "uv: $(uv --version) at $(command -v uv)"
    return
  fi
  log "installing uv to ~/.local/bin..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  ensure_path "$HOME/.local/bin"
  have uv || die "uv install failed; expected at ~/.local/bin/uv"
  log "uv installed: $(uv --version)"
}

# --- step 2: py 3.10 venv ---
ensure_venv() {
  if [[ -x "$LOCAL_VENV/bin/python3" ]]; then
    local pyv
    pyv=$("$LOCAL_VENV/bin/python3" -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
    if [[ "$pyv" == "3.10" ]]; then
      log "venv: $LOCAL_VENV (python $pyv)"
      return
    fi
    log "venv has python $pyv, want 3.10 — recreating"
    rm -rf "$LOCAL_VENV"
  fi
  log "creating venv at $LOCAL_VENV (python 3.10 via uv)..."
  mkdir -p "$LOCAL_REPO"
  ( cd "$LOCAL_REPO" && uv venv --python 3.10 --seed .venv )
  # c7 is Amazon Linux 2 with glibc 2.26 — too old for modern pyarrow manylinux wheels.
  # We only need pip itself on c7 (to pip download platform-tagged wheels for the pod)
  # and `requests` for shard downloads. Everything ML-ish runs inside the pod.
  "$LOCAL_VENV/bin/python" -m pip install --quiet --upgrade pip requests
  log "venv ready: $("$LOCAL_VENV/bin/python" --version)"
}

# --- step 3: kraken/midway auth ---
refresh_auth() {
  ensure_path "$HOME/.toolbox/bin"
  have mwinit || die "mwinit not on PATH; run \`toolbox install midway\` then re-run this script"
  have kraken || die "kraken not on PATH; run \`toolbox install kraken\` then re-run this script"

  # midway cookie freshness — if <12h old, skip mwinit
  local cookie="$HOME/.midway/cookie"
  local need_mwinit=1
  if [[ -f "$cookie" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$cookie" 2>/dev/null || stat -f %m "$cookie") ))
    if (( age < 43200 )); then
      log "midway cookie age ${age}s (<12h), skipping mwinit"
      need_mwinit=0
    fi
  fi
  if (( need_mwinit )); then
    log "running mwinit (interactive)..."
    mwinit
  fi

  # kraken needs the JOB name, not the pod name. Pods are named <job>-worker-N.
  local job="${KRAKEN_JOB:-${POD%-worker-*}}"
  log "refreshing kubectl context for kraken job=$job (pod=$POD)..."
  kraken jobs update-kubeconfig -p obsidian -j "$job" >/dev/null
  kubectl get pod "$POD" >/dev/null 2>&1 || die "kubectl can't see $POD after kraken refresh"
  log "kubectl ok, current context: $(kubectl config current-context)"
}

# --- step 4: pod sanity ---
verify_pod() {
  log "verifying pod env..."
  kubectl exec "$POD" -- bash -c '
    set -e
    nvidia-smi -L | head -1
    python3 --version
    python3 -c "import torch; assert torch.cuda.get_device_capability() == (10,0), torch.cuda.get_device_capability()"
    test -d '"$POD_FSX"' || { echo "FSx '"$POD_FSX"' not mounted"; exit 1; }
  ' 2>&1 | sed 's/^/  /'
}

# --- step 5: stage repo on FSx ---
stage_repo() {
  log "using local repo at $LOCAL_REPO ..."
  [[ -f "$LOCAL_REPO/train.py" && -f "$LOCAL_REPO/program.md" ]] \
    || die "$LOCAL_REPO doesn't look like the autoresearch repo (no train.py/program.md)"

  if [[ -z "${FORCE:-}" ]]; then
    if kubectl exec "$POD" -- bash -c "test -d $POD_REPO/.git" 2>/dev/null; then
      log "repo already staged at pod:$POD_REPO (use FORCE=1 to redo)"
      return
    fi
  fi

  log "shipping repo to pod:$POD_REPO ..."
  kubectl exec "$POD" -- bash -c "rm -rf $POD_REPO && mkdir -p $POD_REPO" >/dev/null
  ( cd "$LOCAL_REPO" && tar czf - --exclude='__pycache__' --exclude='.venv' --exclude='run.log' . ) \
    | kubectl exec -i "$POD" -- bash -c "cd $POD_REPO && tar xzf -" >/dev/null
  kubectl exec "$POD" -- bash -c "
    cd $POD_REPO
    git config --global --add safe.directory $POD_REPO
    git config user.email 'autoresearch-swarm@local'
    git config user.name 'autoresearch-swarm'
    git status --short | head -3
  " 2>&1 | sed 's/^/  /'
}

# --- step 6: wheels ---
stage_wheels() {
  log "downloading + shipping wheels (rustbpe, kernels==0.11.7)..."
  mkdir -p "$LOCAL_WHEELS"
  "$LOCAL_VENV/bin/python" -m pip download --no-deps --dest "$LOCAL_WHEELS" \
    --platform manylinux_2_17_x86_64 --platform manylinux2014_x86_64 \
    --python-version 310 --abi cp310 --only-binary=:all: \
    rustbpe kernels==0.11.7 2>&1 | tail -5 | sed 's/^/  /'

  kubectl exec "$POD" -- bash -c "mkdir -p $POD_REPO/wheels-tmp" >/dev/null
  for whl in "$LOCAL_WHEELS"/*.whl; do
    log "  ship $(basename "$whl")"
    kubectl cp "$whl" "$POD:$POD_REPO/wheels-tmp/$(basename "$whl")" >/dev/null
  done

  kubectl exec "$POD" -- bash -c "
    set -e
    mkdir -p $POD_REPO/wheels
    mv $POD_REPO/wheels-tmp/* $POD_REPO/wheels/ 2>/dev/null || true
    rmdir $POD_REPO/wheels-tmp 2>/dev/null || true
    rm -rf $POD_SITE
    mkdir -p $POD_SITE
    pip install --no-deps --no-index --target=$POD_SITE \
      $POD_REPO/wheels/rustbpe-*.whl \
      $POD_REPO/wheels/kernels-0.11.7-py3-none-any.whl 2>&1 | tail -3
    PYTHONPATH=$POD_SITE python3 -c 'import rustbpe, kernels; print(\"site ok:\", kernels.__version__)'
  " 2>&1 | sed 's/^/  /'
}

# --- step 7: prepare data ---
# Strategy: c7 downloads parquet shards via curl (HF doesn't need ML deps, and c7 has
# internet); ships them to FSx; runs tokenizer training INSIDE the pod (pod has
# pyarrow + tiktoken + rustbpe ready and has the same FSx mount).
# c7's glibc 2.26 is too old to install pyarrow from PyPI, so we don't try.
prepare_data() {
  if [[ -n "${SKIP_PREPARE:-}" ]]; then
    log "SKIP_PREPARE=1, skipping data prep"
    return
  fi
  if [[ -z "${FORCE:-}" ]]; then
    if kubectl exec "$POD" -- bash -c "test -f $POD_CACHE/tokenizer/tokenizer.pkl && ls $POD_CACHE/data/shard_*.parquet >/dev/null 2>&1" 2>/dev/null; then
      log "data already staged at pod:$POD_CACHE (use FORCE=1 to redo)"
      return
    fi
  fi

  log "downloading $NUM_SHARDS+1 parquet shards on c7 (curl, ~1-2 GB)..."
  local stage_data="$LOCAL_STAGE/data"
  mkdir -p "$stage_data"

  # Mirror prepare.py's BASE_URL + naming
  local BASE_URL="https://huggingface.co/datasets/karpathy/climbmix-400b-shuffle/resolve/main"
  local VAL_SHARD=6542
  local ids=()
  for i in $(seq 0 $((NUM_SHARDS - 1))); do ids+=("$i"); done
  ids+=("$VAL_SHARD")

  for i in "${ids[@]}"; do
    local fname
    fname=$(printf "shard_%05d.parquet" "$i")
    if [[ -s "$stage_data/$fname" ]]; then
      continue   # already downloaded
    fi
    log "  curl $fname"
    curl -fsSL --retry 3 --retry-delay 2 -o "$stage_data/$fname.tmp" "$BASE_URL/$fname" \
      && mv "$stage_data/$fname.tmp" "$stage_data/$fname" \
      || die "failed to download $fname"
  done

  log "shipping shards to pod:$POD_CACHE/data/ ..."
  kubectl exec "$POD" -- bash -c "mkdir -p $POD_CACHE/data $POD_CACHE/tokenizer" >/dev/null
  ( cd "$stage_data" && tar cf - shard_*.parquet ) \
    | kubectl exec -i "$POD" -- bash -c "cd $POD_CACHE/data && tar xf -" >/dev/null

  log "training tokenizer inside the pod (uses pod's pyarrow + tiktoken + rustbpe)..."
  kubectl exec "$POD" -- bash -c "
    set -e
    cd $POD_REPO
    export HOME=$POD_FSX
    export PYTHONPATH=$POD_SITE
    # prepare.py downloads then tokenizes — but our shards are already there.
    # Just call train_tokenizer() directly via -c so we skip the download path.
    python3 -c '
import sys; sys.path.insert(0, \".\")
from prepare import train_tokenizer
train_tokenizer()
'
  " 2>&1 | sed 's/^/  /'

  kubectl exec "$POD" -- bash -c "ls $POD_CACHE/data/ | wc -l; ls $POD_CACHE/tokenizer/; du -sh $POD_CACHE" 2>&1 | sed 's/^/  /'
}

# --- step 8: FA2 patch on pod ---
patch_train_py() {
  log "patching train.py for B200 baseline (FA3 -> FA2)..."
  kubectl exec "$POD" -- bash -c '
    set -e
    cd '"$POD_REPO"'
    if grep -q "_FA2Shim" train.py; then
      echo "  patch already in train.py"
    else
      python3 - <<PYEOF
import re, pathlib
p = pathlib.Path("train.py")
src = p.read_text()
old = """from kernels import get_kernel
cap = torch.cuda.get_device_capability()
# varunneal'"'"'s FA3 is Hopper only, use kernels-community on non-Hopper GPUs
repo = "varunneal/flash-attention-3" if cap == (9, 0) else "kernels-community/flash-attn3"
fa3 = get_kernel(repo).flash_attn_interface"""
new = """cap = torch.cuda.get_device_capability()
# B200 (sm_100) baseline uses pre-installed flash_attn 2.7.3 which supports Blackwell.
from flash_attn import flash_attn_func
class _FA2Shim:
    flash_attn_func = staticmethod(flash_attn_func)
fa3 = _FA2Shim()"""
if old not in src:
    raise SystemExit("expected FA3 import block not found in train.py — manual fix needed")
p.write_text(src.replace(old, new))
print("  patched train.py")
PYEOF
    fi
    git add train.py
    if ! git diff --cached --quiet; then
      git commit -m "swap FA3 -> FA2 for B200 (Blackwell sm_100) baseline" 2>&1 | tail -2
    else
      echo "  no change to commit"
    fi
  ' 2>&1 | sed 's/^/  /'
}

# --- step 9: smoke ---
smoke_test() {
  if [[ -n "${SKIP_SMOKE:-}" ]]; then
    log "SKIP_SMOKE=1, skipping smoke test"
    return
  fi
  log "smoke testing on GPU 0 (~5 min train + ~1 min eval)..."
  kubectl exec "$POD" -- bash -c "
    set -e
    cd $POD_REPO
    export HOME=$POD_FSX
    export PYTHONPATH=$POD_SITE
    export HF_HUB_OFFLINE=1
    export PYTORCH_ALLOC_CONF=expandable_segments:True
    export CUDA_VISIBLE_DEVICES=0
    python3 train.py > smoke.log 2>&1
    grep '^val_bpb:\|^training_seconds:\|^peak_vram_mb:\|^mfu_percent:\|^num_steps:' smoke.log
  " 2>&1 | sed 's/^/  /' || die "smoke test failed; check pod:$POD_REPO/smoke.log"
}

# --- main ---
ensure_uv
ensure_venv
refresh_auth
verify_pod
stage_repo
stage_wheels
prepare_data
patch_train_py
smoke_test

log "bootstrap complete."
log "  next: bash $LOCAL_REPO/scripts/swarm.sh up"
log "  also: bash $LOCAL_REPO/scripts/c7_auth_check.sh --install-cron   # set up cred-expiry alerts"
