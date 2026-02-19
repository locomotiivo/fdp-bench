#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Common environment for all FDP benchmarks (Ethereum, Sui, etc.)
# ═══════════════════════════════════════════════════════════════════════
#
# Sources once per shell — provides device paths, FDP tooling locations,
# host SSH config, and the filesystem prepare/teardown functions shared
# by all blockchain benchmarks.
#
# Usage:
#   source "$(dirname "$0")/../common/env.sh"
#   # or from eth-bench/scripts/:
#   source "$SCRIPT_DIR/../../common/env.sh"
#
[[ -n "${_COMMON_ENV_SOURCED:-}" ]] && return 0
_COMMON_ENV_SOURCED=1

set -euo pipefail

# ── Device and mount ──────────────────────────────────────────────────
export NVME_DEV="${NVME_DEV:-/dev/nvme0n1}"
export MOUNT_POINT="${MOUNT_POINT:-$HOME/f2fs_fdp_mount}"

# ── FDP tooling (f2fs-tools-fdp, fdp_stats) ──────────────────────────
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FDP_TOOLS="${FDP_TOOLS:-$COMMON_DIR/../f2fs-tools-fdp}"
export FDP_STATS="${FDP_STATS:-$COMMON_DIR/fdp_stats}"

# ── Host SSH for FEMU stats ──────────────────────────────────────────
export HOST_IP="${HOST_IP:-10.0.2.2}"
export HOST_USER="${HOST_USER:-hajin}"
export HOST_FEMU_LOG="${HOST_FEMU_LOG:-/home/hajin/femu-scripts/run-fdp.log}"

# ── Shared helpers ────────────────────────────────────────────────────

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Format + mount F2FS with the given number of FDP streams.
# Usage: prepare_fs <streams>
prepare_fs() {
  local streams="$1"
  log "Unmounting $MOUNT_POINT (if mounted)"
  sudo umount "$MOUNT_POINT" 2>/dev/null || true
  sleep 1

  log "Formatting F2FS on $NVME_DEV"
  sudo "$FDP_TOOLS/mkfs/mkfs.f2fs" -f -O lost_found "$NVME_DEV" >/dev/null

  log "Mounting with $streams stream(s)"
  sudo "$FDP_TOOLS/fdp_f2fs_mount" "$streams"
  sudo chmod -R 777 "$MOUNT_POINT"
}

# Unmount and clean up.
teardown_fs() {
  sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
  sudo umount "$MOUNT_POINT" 2>/dev/null || true
}

# Reset FEMU FTL counters.
reset_femu_counters() {
  log "Resetting FEMU FTL counters"
  sudo "$FDP_STATS" "$NVME_DEV" --reset >/dev/null || true
  sleep 2
}

# Get WAF value from FEMU host log (via SSH).
# Returns numeric WAF or "N/A".
get_waf_from_host() {
  local raw
  raw=$(
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        "${HOST_USER}@${HOST_IP}" \
        "tail -100 '$HOST_FEMU_LOG' | tr -d '\0' | grep -iE 'WAF'" 2>/dev/null | tail -1
  ) || true
  local waf
  waf=$(echo "$raw" | grep -oP '[0-9]+\.[0-9]+' | tail -1) || true
  echo "${waf:-N/A}"
}

# Get FEMU raw stats (Host written, GC copied, WAF lines).
get_femu_raw_stats() {
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      "${HOST_USER}@${HOST_IP}" \
      "tail -100 '$HOST_FEMU_LOG' | tr -d '\0' | grep -E 'Host written|GC copied|WAF:'" 2>/dev/null | tail -5 || true
}

# Trigger fdp_stats read (prints stats to FEMU host log, not stdout).
snapshot_femu() {
  sudo "$FDP_STATS" "$NVME_DEV" --read-only >/dev/null 2>&1 || true
  sleep 2
}

# Compute percentage change: ((new - base) / |base|) × 100.
# Prints "+X.Y%" or "N/A" if inputs are missing/zero.
pct_change() {
  python3 -c "
b, n = '$1', '$2'
if b in ('', '0', '0.0', 'N/A', 'None') or n in ('', 'N/A', 'None'):
    print('N/A')
else:
    b, n = float(b), float(n)
    if abs(b) < 1e-9:
        print('N/A')
    else:
        d = ((n - b) / abs(b)) * 100
        print(f'{d:+.1f}%')
" 2>/dev/null || echo "N/A"
}

# Collect per-PID disk usage.
# Usage: pid_disk_usage "label"
pid_disk_usage() {
  local label="$1"
  echo "--- [$label] Per-PID disk usage ---"
  for p in p0 p1 p2 p3 p4 p5 p6 p7; do
    local d="$MOUNT_POINT/$p"
    if [ -d "$d" ]; then
      local sz
      sz=$(du -sh "$d" 2>/dev/null | cut -f1)
      printf "  %-4s  %s\n" "$p" "$sz"
    fi
  done
}

# ── Shared Helpers ────────────────────────────────────────────────────

# Human-readable duration from seconds.
secs_to_duration() {
  local s="${1:-0}"
  printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
}

# Read a key=value metric from a file.
load_metric() {
  local file="$1" key="$2"
  grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2 || echo "0"
}
