#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# FDP Ethereum Mainnet Replay Benchmark
# ═══════════════════════════════════════════════════════════════════════
#
# Replays real Ethereum mainnet blocks on the FDP SSD, following the
# methodology of LVMT (OSDI '23), Ethanos (EuroSys '21), and LMPTs
# (IEEE ICBC '22).
#
# 2-Phase Design:
#   Phase 1 (Warmup):  Replay blocks 0..N to fill DB with realistic
#                      state distribution and reach SSD steady state.
#   Phase 2 (Measure): Continue replaying blocks N+1..M while measuring
#                      WAF, compaction stats, and I/O metrics.
#
# Block data source: Ethereum Era1 archives (pre-merge blocks packed in
# epochs of 8192 blocks), downloaded from era1.ethportal.net.
#
# Usage:
#   # Step 1: Download era1 files (one-time):
#   ./bench.sh download 0 600000
#
#   # Step 2: Convert era1 → RLP (one-time):
#   ./bench.sh convert
#
#   # Step 3: Run FDP vs non-FDP replay benchmark:
#   ./bench.sh bench
#
#   # Or run only one mode:
#   ./bench.sh bench fdp
#   ./bench.sh bench nofdp
#
# Prerequisites:
#   - geth binary with FDP Pebble patches (~/go-ethereum/build/bin/geth)
#   - era2rlp binary (~/go-ethereum/build/bin/era2rlp)
#   - Era1 files in $ERA_DIR (downloaded via `./bench.sh download`)
#   - FDP SSD mounted (handled automatically)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source environment
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/helpers.sh"

# ═══════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════

# Era1 download settings
ERA_SERVER="${ERA_SERVER:-https://era1.ethportal.net}"
ERA_DIR="${ERA_DIR:-$SCRIPT_DIR/../era1}"

# Binaries
ERA2RLP_BIN="${ERA2RLP_BIN:-$HOME/go-ethereum/build/bin/era2rlp}"

# Block range for replay.
# For a 64 GB FEMU SSD with no compression:
#   - Early Ethereum blocks (0-600K) produce only ~200 MB of state
#   - Transaction volume grows sharply from block ~2M onward (ICOs, DeFi)
#   - By block 3-4M, uncompressed state DB reaches ~30-60 GB
#   - GC onset at ~75% utilization (74 of 98 flash lines consumed)
#
# Default: 3.2M blocks — fills the 64 GB SSD past GC onset + ~30 min
# sustained GC under the default gc_thres_pcent=75 threshold.
# From empirical observation (gc_thres_pcent=60, 2.45M blocks):
#   - Blocks 0-2M import fast (~65 min), consuming ~42 of 98 flash lines
#   - Blocks 2M-2.42M import slowly (state trie complexity)
#   - GC triggers at ~60% utilization (58 lines) ≈ block 2.42M
#   - WAF climbs rapidly during GC (4.74 non-FDP, 2.41 FDP)
# With gc_thres_pcent=75 (default), GC onset is delayed to ~block 2.84M.
# 3.2M gives ~30+ min of sustained GC after onset at the higher threshold.
# Data is downloaded and imported in chunks to fit on the host disk.
TOTAL_BLOCKS="${TOTAL_BLOCKS:-3200000}"

# Chunk size for download → convert → import pipeline.
# Each chunk is independently downloaded as era1, converted to RLP,
# imported into geth, then the temporary RLP is deleted.
# 500K blocks ≈ 61 era1 epochs ≈ 1-8 GB of RLP (grows with block number).
CHUNK_BLOCKS="${CHUNK_BLOCKS:-500000}"

# Geth import settings
CACHE_MB="${CACHE_MB:-2048}"

# Monitoring interval (seconds between FEMU stat snapshots during replay)
MONITOR_INTERVAL="${MONITOR_INTERVAL:-300}"   # every 5 min

RESULTS_DIR="$SCRIPT_DIR/../results"
RESULT_FILE="$SCRIPT_DIR/../results_eth.txt"

# ═══════════════════════════════════════════════════════════════════════
# Era1 Download
# ═══════════════════════════════════════════════════════════════════════

download_era1() {
  local first_block="${1:-0}"
  local last_block="${2:-$TOTAL_BLOCKS}"

  mkdir -p "$ERA_DIR"

  log "Downloading Era1 files for blocks $first_block..$last_block"
  log "  Server: $ERA_SERVER"
  log "  Destination: $ERA_DIR"

  # geth download-era uses --block for a block range
  "$GETH_BIN" download-era \
    --server "$ERA_SERVER" \
    --block "${first_block}-${last_block}" \
    --datadir.era "$ERA_DIR" \
    2>&1 | tee "$ERA_DIR/download.log"

  local n_files
  n_files=$(find "$ERA_DIR" -name '*.era1' 2>/dev/null | wc -l)
  log "Downloaded $n_files era1 files to $ERA_DIR"
}

# ═══════════════════════════════════════════════════════════════════════
# Chunked Convert + Import
# ═══════════════════════════════════════════════════════════════════════
#
# Converts era1 → RLP and imports in chunks, keeping only one chunk's
# RLP on disk at a time.  Era1 files stay on disk for reuse.
#

import_chunked() {
  local data_root="$1"
  local dir_ancient="$2"
  local log_file="$3"

  local block=0
  local chunk_id=0

  while [[ $block -lt $TOTAL_BLOCKS ]]; do
    local chunk_end=$((block + CHUNK_BLOCKS))
    [[ $chunk_end -gt $TOTAL_BLOCKS ]] && chunk_end=$TOTAL_BLOCKS

    local chunk_rlp="$ERA_DIR/chunk_${chunk_id}.rlp"
    log ""
    log "── Chunk $chunk_id: blocks $block → $chunk_end ──"

    # 1. Convert this chunk's era1 files to RLP
    log "  Converting era1 → RLP (min=$block max=$chunk_end)"
    local convert_start_ts
    convert_start_ts=$(date +%s)
    "$ERA2RLP_BIN" "$ERA_DIR" "$chunk_rlp" "$chunk_end" "$block" 2>&1

    if [[ ! -f "$chunk_rlp" ]]; then
      log "ERROR: RLP chunk was not created: $chunk_rlp"
      return 1
    fi

    local chunk_size convert_end_ts convert_dur
    chunk_size=$(du -sh "$chunk_rlp" | cut -f1)
    convert_end_ts=$(date +%s)
    convert_dur=$((convert_end_ts - convert_start_ts))
    log "  RLP chunk ready: $chunk_size (converted in $(secs_to_duration $convert_dur))"

    # 2. Import this chunk
    log "  Importing into geth ..."
    local import_chunk_start_ts
    import_chunk_start_ts=$(date +%s)

    "$GETH_BIN" \
      --datadir "$data_root" \
      --datadir.ancient "$dir_ancient" \
      --cache "$CACHE_MB" \
      --state.scheme hash \
      --snapshot=false \
      import "$chunk_rlp" \
      2>&1 | tee -a "$log_file"

    local import_chunk_end_ts import_chunk_dur
    import_chunk_end_ts=$(date +%s)
    import_chunk_dur=$((import_chunk_end_ts - import_chunk_start_ts))

    # 3. Delete chunk RLP to free disk space
    rm -f "$chunk_rlp"
    log "  Chunk $chunk_id done — import $(secs_to_duration $import_chunk_dur), RLP deleted"

    block=$chunk_end
    chunk_id=$((chunk_id + 1))
  done

  log ""
  log "All $chunk_id chunks imported (blocks 0..$TOTAL_BLOCKS)"
}

# ═══════════════════════════════════════════════════════════════════════
# Convert Era1 → RLP (standalone, for manual use / small block counts)
# ═══════════════════════════════════════════════════════════════════════

convert_era1() {
  local rlp_file="$ERA_DIR/blocks.rlp"

  if [[ -f "$rlp_file" ]]; then
    local size
    size=$(du -sh "$rlp_file" | cut -f1)
    log "RLP file already exists: $rlp_file ($size)"
    log "  Delete it to reconvert."
    return 0
  fi

  if [[ ! -x "$ERA2RLP_BIN" ]]; then
    log "ERROR: era2rlp binary not found at $ERA2RLP_BIN"
    log "       Build it: cd ~/go-ethereum && go build -o build/bin/era2rlp ./cmd/era2rlp/"
    return 1
  fi

  local n_files
  n_files=$(find "$ERA_DIR" -name '*.era1' 2>/dev/null | wc -l)
  if [[ "$n_files" -eq 0 ]]; then
    log "ERROR: No .era1 files found in $ERA_DIR"
    log "       Run: ./bench.sh download 0 $TOTAL_BLOCKS"
    return 1
  fi

  log "Converting $n_files era1 files → RLP (max block: $TOTAL_BLOCKS)"
  log "  Input:  $ERA_DIR/*.era1"
  log "  Output: $rlp_file"
  log ""

  "$ERA2RLP_BIN" "$ERA_DIR" "$rlp_file" "$TOTAL_BLOCKS" 2>&1

  local size
  size=$(du -sh "$rlp_file" | cut -f1)
  log ""
  log "RLP file ready: $rlp_file ($size)"
}

# ═══════════════════════════════════════════════════════════════════════
# Background Monitor — periodic FEMU/disk stats during replay
# ═══════════════════════════════════════════════════════════════════════

MONITOR_PID=""

start_monitor() {
  local stats_log="$1"
  local interval="${2:-$MONITOR_INTERVAL}"

  (
    while true; do
      local ts
      ts=$(date '+%Y-%m-%d %H:%M:%S')

      snapshot_femu
      local waf
      waf=$(get_waf_from_host)

      local disk_used
      disk_used=$(du -s "$MOUNT_POINT" 2>/dev/null | cut -f1)
      local disk_used_mb=$((disk_used / 1024))

      echo "$ts  disk_mb=$disk_used_mb  waf=$waf" >> "$stats_log"
      sleep "$interval"
    done
  ) &
  MONITOR_PID=$!
  log "Background monitor started (PID=$MONITOR_PID, interval=${interval}s)"
}

stop_monitor() {
  if [[ -n "${MONITOR_PID:-}" ]]; then
    kill "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# run_replay  STREAMS  LABEL
# ═══════════════════════════════════════════════════════════════════════
#
# Runs one complete replay round:
#   format → mount → import blocks (full EVM re-execution) → collect metrics
#
run_replay() {
  local streams="$1"
  local label="$2"
  local rdir="$RESULTS_DIR/$label"
  rm -rf "$rdir"
  mkdir -p "$rdir"

  log ""
  log "╔═══════════════════════════════════════════════════════════════╗"
  log "║  Replay round: $label  (STREAMS=$streams)                   "
  log "║  Total blocks: ${TOTAL_BLOCKS}                              "
  log "╚═══════════════════════════════════════════════════════════════╝"

  export STREAMS="$streams"

  # ── 1. Prepare filesystem ──────────────────────────────────────────
  prepare_fs "$streams"

  # Re-source env.sh to pick up new MOUNT_POINT paths
  _ETH_ENV_SOURCED=""
  source "$SCRIPT_DIR/env.sh"

  if [[ "$streams" -gt 1 ]]; then
    log "FDP mode ($streams streams)"
  else
    log "Non-FDP baseline (single stream)"
  fi

  reset_femu_counters

  # ── 2. Create chaindata directory structure ────────────────────────
  mkdir -p "$DIR_WAL" "$DIR_FLUSH" "$DIR_L0CMP" "$DIR_MIDCMP" "$DIR_CHAINDATA" \
           "$DIR_ANCIENT" "$DIR_LOGS"

  local geth_internal="$DATA_ROOT/geth"
  mkdir -p "$geth_internal"
  if [ ! -e "$geth_internal/chaindata" ]; then
    ln -s "$DIR_CHAINDATA" "$geth_internal/chaindata"
  fi

  # ── 3. Set FDP environment variables ───────────────────────────────
  if [[ "$streams" -gt 1 ]]; then
    export GETH_FDP_ENABLED=1
    export GETH_FDP_WAL_DIR="$DIR_WAL"
    export GETH_FDP_FLUSH_DIR="$DIR_FLUSH"
    export GETH_FDP_L0CMP_DIR="$DIR_L0CMP"
    export GETH_FDP_MIDCMP_DIR="$DIR_MIDCMP"
    log "FDP VFS: WAL=$DIR_WAL  FLUSH=$DIR_FLUSH  L0CMP=$DIR_L0CMP  MIDCMP=$DIR_MIDCMP"
  else
    export GETH_FDP_ENABLED=0
    unset GETH_FDP_WAL_DIR GETH_FDP_FLUSH_DIR GETH_FDP_L0CMP_DIR GETH_FDP_MIDCMP_DIR 2>/dev/null || true
    log "FDP VFS disabled"
  fi

  export GETH_PEBBLE_NO_COMPRESSION="${GETH_PEBBLE_NO_COMPRESSION:-1}"
  export GETH_PEBBLE_MEMTABLE_MB="${GETH_PEBBLE_MEMTABLE_MB:-16}"
  log "Pebble: compression=off, memtable=${GETH_PEBBLE_MEMTABLE_MB}MB"

  # ── 4. Check era1 files and era2rlp binary ──────────────────────────
  local n_era1_files
  n_era1_files=$(find "$ERA_DIR" -name '*.era1' 2>/dev/null | wc -l)
  if [[ "$n_era1_files" -eq 0 ]]; then
    log "ERROR: No era1 files found in $ERA_DIR"
    log "       Run: ./bench.sh download"
    return 1
  fi
  if [[ ! -x "$ERA2RLP_BIN" ]]; then
    log "ERROR: era2rlp binary not found at $ERA2RLP_BIN"
    return 1
  fi

  # ── 5. Import blocks via chunked pipeline ──────────────────────────
  #
  # Converts era1→RLP and imports in CHUNK_BLOCKS-sized pieces,
  # keeping only one chunk's RLP on disk at a time.
  #
  log ""
  log "═══ Importing blocks (full EVM re-execution, chunked) ═══"
  log "  Era1 dir: $ERA_DIR ($n_era1_files files)"
  log "  Total blocks: $TOTAL_BLOCKS (chunk size: $CHUNK_BLOCKS)"
  log "  Cache: ${CACHE_MB}MB"
  log "  State scheme: hash"
  log "  Snapshot: disabled"

  start_monitor "$rdir/monitor.log"

  local import_start_ts
  import_start_ts=$(date +%s)

  import_chunked "$DATA_ROOT" "$DIR_ANCIENT" "$rdir/import.log"

  local import_end_ts
  import_end_ts=$(date +%s)
  local import_duration=$((import_end_ts - import_start_ts))

  stop_monitor
  log "Import complete in $(secs_to_duration $import_duration)"

  # ── 6. Collect FEMU stats ──────────────────────────────────────────
  snapshot_femu
  sleep 2
  local waf_value femu_raw
  waf_value=$(get_waf_from_host)
  femu_raw=$(get_femu_raw_stats)

  pid_disk_usage "$label" > "$rdir/disk_usage.txt"

  # ── 7. Extract metrics from import.log ─────────────────────────────
  # geth import calls chain.Stop() then Compact(), logging stats.
  # Each chunk is a separate geth process, so we SUM stats across all chunks.
  local m_stall_count m_stall_time_ms m_compaction_time_ms
  m_stall_count=$(grep -i 'write stall' "$rdir/import.log" 2>/dev/null | grep -oP 'stall_count=\K[0-9,]+' | tr -d ',' | awk '{s+=$1} END{print s+0}' || echo "0")
  m_stall_time_ms=$(grep -i 'write stall' "$rdir/import.log" 2>/dev/null | grep -oP 'stall_time_ms=\K[0-9,]+' | tr -d ',' | awk '{s+=$1} END{print s+0}' || echo "0")
  m_compaction_time_ms=$(grep -i 'write stall' "$rdir/import.log" 2>/dev/null | grep -oP 'compaction_time_ms=\K[0-9,]+' | tr -d ',' | awk '{s+=$1} END{print s+0}' || echo "0")

  # Extract last reported block number and import speed from geth output
  local blocks_imported
  blocks_imported=$(grep -oP 'number=\K[0-9,]+' "$rdir/import.log" 2>/dev/null | tail -1 | tr -d ',' || echo "0")
  local bps
  bps=$(python3 -c "print(f'{${blocks_imported:-0} / max(${import_duration},1):.2f}')" 2>/dev/null || echo "0")

  # Compute average Mgas/sec from total gas and total time
  # The instantaneous mgasps varies wildly (50 early → 0.5 late), so use average
  local total_mgas mgps
  total_mgas=$(grep -oP 'mgas=\K[0-9.]+' "$rdir/import.log" 2>/dev/null | awk '{s+=$1} END{print s+0}' || echo "0")
  mgps=$(python3 -c "print(f'{${total_mgas:-0} / max(${import_duration},1):.3f}')" 2>/dev/null || echo "0")

  teardown_fs

  # ── 8. Save metrics ───────────────────────────────────────────────
  cat > "$rdir/metrics.txt" <<EOF
label=$label
streams=$streams
mode=replay
total_blocks=${blocks_imported:-0}
import_duration_s=$import_duration
blocks_per_sec=$bps
mgas_per_sec=$mgps
waf=$waf_value
stall_count=${m_stall_count:-0}
stall_time_ms=${m_stall_time_ms:-0}
compaction_time_ms=${m_compaction_time_ms:-0}
EOF

  local stall_disp comp_disp
  stall_disp=$(python3 -c "print(f'{int(\"${m_stall_time_ms:-0}\")/1000:.1f}s')")
  comp_disp=$(python3 -c "print(f'{int(\"${m_compaction_time_ms:-0}\")/1000:.1f}s')")

  cat > "$rdir/summary.txt" <<EOF
=== Mainnet Replay: $label (STREAMS=$streams) ===
Date: $(date)
Blocks imported: ${blocks_imported:-0}
Duration: $(secs_to_duration $import_duration)
Blocks/sec: $bps
Mgas/sec: $mgps
WAF: $waf_value
Write Stalls: ${m_stall_count:-0} (total time: $stall_disp)
Compaction Time: $comp_disp

--- Disk Usage ---
$(cat "$rdir/disk_usage.txt" 2>/dev/null)

--- FEMU FTL Stats ---
$femu_raw
EOF

  log "Round '$label' complete."
  log "  Blocks=$blocks_imported  Duration=$(secs_to_duration $import_duration)"
  log "  WAF=$waf_value  Stalls=$m_stall_count  Compaction=$comp_disp"
}

# ═══════════════════════════════════════════════════════════════════════
# Comparison Table
# ═══════════════════════════════════════════════════════════════════════

print_replay_comparison() {
  local nfdp_file="$1" fdp_file="$2"

  local n_blocks f_blocks n_dur f_dur n_bps f_bps n_waf f_waf
  local n_stalls f_stalls n_stall_ms f_stall_ms n_comp_ms f_comp_ms
  local n_mgps f_mgps

  n_blocks=$(load_metric "$nfdp_file" total_blocks)
  f_blocks=$(load_metric "$fdp_file" total_blocks)
  n_dur=$(load_metric "$nfdp_file" import_duration_s)
  f_dur=$(load_metric "$fdp_file" import_duration_s)
  n_bps=$(load_metric "$nfdp_file" blocks_per_sec)
  f_bps=$(load_metric "$fdp_file" blocks_per_sec)
  n_mgps=$(load_metric "$nfdp_file" mgas_per_sec)
  f_mgps=$(load_metric "$fdp_file" mgas_per_sec)
  n_waf=$(load_metric "$nfdp_file" waf)
  f_waf=$(load_metric "$fdp_file" waf)
  n_stalls=$(load_metric "$nfdp_file" stall_count)
  f_stalls=$(load_metric "$fdp_file" stall_count)
  n_stall_ms=$(load_metric "$nfdp_file" stall_time_ms)
  f_stall_ms=$(load_metric "$fdp_file" stall_time_ms)
  n_comp_ms=$(load_metric "$nfdp_file" compaction_time_ms)
  f_comp_ms=$(load_metric "$fdp_file" compaction_time_ms)

  local n_dur_disp f_dur_disp n_stall_disp f_stall_disp n_comp_disp f_comp_disp
  n_dur_disp=$(secs_to_duration "${n_dur:-0}")
  f_dur_disp=$(secs_to_duration "${f_dur:-0}")
  n_stall_disp=$(python3 -c "print(f'{int(\"${n_stall_ms:-0}\")/1000:.1f}s')" 2>/dev/null || echo "N/A")
  f_stall_disp=$(python3 -c "print(f'{int(\"${f_stall_ms:-0}\")/1000:.1f}s')" 2>/dev/null || echo "N/A")
  n_comp_disp=$(python3 -c "print(f'{int(\"${n_comp_ms:-0}\")/1000:.1f}s')" 2>/dev/null || echo "N/A")
  f_comp_disp=$(python3 -c "print(f'{int(\"${f_comp_ms:-0}\")/1000:.1f}s')" 2>/dev/null || echo "N/A")

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "         Mainnet Replay: Non-FDP vs FDP Comparison"
  echo "═══════════════════════════════════════════════════════════════════════"
  printf "  %-22s %14s %14s %10s\n" "Metric" "Non-FDP" "FDP" "Delta"
  echo "───────────────────────────────────────────────────────────────────────"
  printf "  %-22s %14s %14s %10s\n" "Blocks Imported"     "$n_blocks"      "$f_blocks"      ""
  printf "  %-22s %14s %14s %10s\n" "Duration"            "$n_dur_disp"    "$f_dur_disp"    "$(pct_change "$n_dur" "$f_dur")"
  printf "  %-22s %14s %14s %10s\n" "Blocks/sec"          "$n_bps"         "$f_bps"         "$(pct_change "$n_bps" "$f_bps")"
  printf "  %-22s %14s %14s %10s\n" "Mgas/sec"            "$n_mgps"        "$f_mgps"        "$(pct_change "$n_mgps" "$f_mgps")"
  printf "  %-22s %14s %14s %10s\n" "WAF"                 "$n_waf"         "$f_waf"         "$(pct_change "$n_waf" "$f_waf")"
  printf "  %-22s %14s %14s %10s\n" "Write Stalls"        "$n_stalls"      "$f_stalls"      "$(pct_change "$n_stalls" "$f_stalls")"
  printf "  %-22s %14s %14s %10s\n" "Stall Time"          "$n_stall_disp"  "$f_stall_disp"  "$(pct_change "$n_stall_ms" "$f_stall_ms")"
  printf "  %-22s %14s %14s %10s\n" "Compaction Time"     "$n_comp_disp"   "$f_comp_disp"   "$(pct_change "$n_comp_ms" "$f_comp_ms")"
  echo "───────────────────────────────────────────────────────────────────────"
  echo "  Workload: Ethereum mainnet block replay (full EVM re-execution)"
  echo "  For Blocks/sec & Mgas/sec: positive delta = FDP is better"
  echo "  For WAF, Stalls & Compaction: negative delta = FDP is better"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

usage() {
  echo "Usage: $0 <command> [args]"
  echo ""
  echo "Commands:"
  echo "  download [first] [last]   Download era1 files (default: 0-${TOTAL_BLOCKS})"
  echo "  convert                   Convert era1 → single RLP (manual/small ranges)"
  echo "  bench [fdp|nofdp|both]    Run replay benchmark (auto-chunks era1→RLP→import)"
  echo ""
  echo "Environment variables:"
  echo "  TOTAL_BLOCKS   Total blocks to replay (default: 5000000)"
  echo "  CHUNK_BLOCKS   Blocks per import chunk (default: 500000)"
  echo "  CACHE_MB       Geth cache size in MB (default: 2048)"
  echo "  ERA_DIR        Directory for era1 files (default: ../era1)"
  echo "  ERA_SERVER     Era1 download server URL"
  echo "  ERA2RLP_BIN    Path to era2rlp binary"
  exit 1
}

CMD="${1:-}"
shift || true

case "$CMD" in
  download)
    download_era1 "${1:-0}" "${2:-$TOTAL_BLOCKS}"
    ;;

  convert)
    convert_era1
    ;;

  bench)
    MODE_ARG="${1:-both}"
    mkdir -p "$RESULTS_DIR"

    cleanup_on_exit() {
      log "Cleaning up (EXIT trap) ..."
      stop_monitor
      teardown_fs 2>/dev/null || true
    }
    trap cleanup_on_exit EXIT

    if [[ "$MODE_ARG" == "nofdp" || "$MODE_ARG" == "both" ]]; then
      run_replay 1 "non-fdp"
      sleep 10
    fi

    if [[ "$MODE_ARG" == "fdp" || "$MODE_ARG" == "both" ]]; then
      run_replay 8 "fdp"
    fi

    if [[ "$MODE_ARG" == "both" ]]; then
      log "Both rounds complete — generating comparison ..."
      NFDP="$RESULTS_DIR/non-fdp/metrics.txt"
      FDP_M="$RESULTS_DIR/fdp/metrics.txt"
      print_replay_comparison "$NFDP" "$FDP_M"

      {
        echo "=== FDP Ethereum Mainnet Replay — Comparison Report ==="
        echo "Date: $(date)"
        echo ""
        print_replay_comparison "$NFDP" "$FDP_M"
        echo ""
        echo "──────────────── Non-FDP Details ────────────────"
        cat "$RESULTS_DIR/non-fdp/summary.txt" 2>/dev/null
        echo ""
        echo "──────────────── FDP Details ────────────────────"
        cat "$RESULTS_DIR/fdp/summary.txt" 2>/dev/null
      } > "$RESULT_FILE"
      log "Report saved to $RESULT_FILE"
    fi
    ;;

  *)
    usage
    ;;
esac
