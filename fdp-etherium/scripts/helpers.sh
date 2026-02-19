#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Ethereum benchmark helper functions
# ═══════════════════════════════════════════════════════════════════════
#
# Sourced by bench.sh.  Contains parsing, metrics collection, and
# EL/CL lifecycle functions.  Does NOT contain workload logic.
#
[[ -n "${_ETH_HELPERS_SOURCED:-}" ]] && return 0
_ETH_HELPERS_SOURCED=1

# NOTE: secs_to_duration() and load_metric() are in common/env.sh.
# The eth-bench overrides secs_to_duration with a compact format.
secs_to_duration() {
  local s="${1:-0}"
  if [[ "$s" -ge 3600 ]]; then
    printf '%dh%02dm%02ds' $((s/3600)) $((s%3600/60)) $((s%60))
  else
    printf '%dm%ds' $((s/60)) $((s%60))
  fi
}

# ── JSON-RPC: current block number (decimal) ─────────────────────────
get_block_number() {
  curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://127.0.0.1:8545 2>/dev/null | \
    python3 -c 'import sys,json; r=json.load(sys.stdin); print(int(r["result"],16))' 2>/dev/null || echo "0"
}

# ── Parse spamoor throughput (60-block average tx/block) ──────────────
parse_throughput_txb() {
  grep -oP '60B=\K[0-9.]+' "$1" 2>/dev/null | tail -1 || echo "0"
}

# ── Count confirmed txs across a block range (batch JSON-RPC) ────────
count_confirmed_txs() {
  local start_block="$1"
  local end_block="$2"
  python3 -c "
import json, urllib.request
total = 0
batch = []
for b in range($start_block + 1, $end_block + 1):
    batch.append({'jsonrpc':'2.0','method':'eth_getBlockTransactionCountByNumber',
                  'params':[hex(b)],'id':b})
    if len(batch) >= 200 or b == $end_block:
        req = urllib.request.Request('http://127.0.0.1:8545',
              data=json.dumps(batch).encode(),
              headers={'Content-Type':'application/json'})
        try:
            resp = json.loads(urllib.request.urlopen(req, timeout=30).read())
            total += sum(int(r['result'],16) for r in resp if r.get('result'))
        except Exception:
            pass
        batch = []
print(total)
" 2>/dev/null || echo "0"
}

# ── Scrape Pebble metrics from geth's HTTP debug endpoint ────────────
# Populates: live_stall_count, live_l0_comp, live_nonl0_comp
# Saves raw metrics to $1/pebble_metrics_raw.txt
scrape_pebble_metrics() {
  local rdir="$1"
  local metrics_raw
  live_stall_count=0
  live_stall_time_ms=0
  live_compaction_time_ms=0
  live_l0_comp=0
  live_nonl0_comp=0

  if metrics_raw=$(curl -sf http://127.0.0.1:6060/debug/metrics 2>/dev/null); then
    local sc_l0 sc_mem
    sc_l0=$(echo "$metrics_raw" | grep -oP 'eth/db/chaindata/stall/count/L0[^/].*?:\s*\K[0-9]+' | head -1 || echo 0)
    sc_mem=$(echo "$metrics_raw" | grep -oP 'eth/db/chaindata/stall/count/memtable[^/].*?:\s*\K[0-9]+' | head -1 || echo 0)
    live_stall_count=$(( ${sc_l0:-0} + ${sc_mem:-0} ))
    live_l0_comp=$(echo "$metrics_raw" | grep -oP 'eth/db/chaindata/compact/level0[^/].*?:\s*\K[0-9]+' | head -1 || echo 0)
    live_nonl0_comp=$(echo "$metrics_raw" | grep -oP 'eth/db/chaindata/compact/nonlevel0[^/].*?:\s*\K[0-9]+' | head -1 || echo 0)
    log "Live metrics scraped: stalls=$live_stall_count (L0=${sc_l0:-0} mem=${sc_mem:-0}), L0comp=${live_l0_comp}, nonL0comp=${live_nonl0_comp}"
    echo "$metrics_raw" > "$rdir/pebble_metrics_raw.txt"
  else
    log "WARNING: Could not scrape metrics endpoint (geth may already be down)"
  fi
}

# ── Parse Pebble write-stall stats from geth.log ─────────────────────
# Prefers geth.log (logged at graceful Close()), falls back to live-scraped HTTP metrics.
# Populates: m_stall_count, m_stall_time_ms, m_compaction_time_ms
parse_stall_stats() {
  local geth_log="$1"
  local log_stall_count log_stall_time_ms log_compaction_time_ms

  log_stall_count=$(grep 'write stall stats' "$geth_log" 2>/dev/null | grep -oP 'stall_count=\K[0-9,]+' | tail -1 | tr -d ',' || echo "")
  log_stall_time_ms=$(grep 'write stall stats' "$geth_log" 2>/dev/null | grep -oP 'stall_time_ms=\K[0-9,]+' | tail -1 | tr -d ',' || echo "")
  log_compaction_time_ms=$(grep 'write stall stats' "$geth_log" 2>/dev/null | grep -oP 'compaction_time_ms=\K[0-9,]+' | tail -1 | tr -d ',' || echo "")

  if [[ -n "$log_stall_count" ]]; then
    m_stall_count="$log_stall_count"
    m_stall_time_ms="${log_stall_time_ms:-0}"
    m_compaction_time_ms="${log_compaction_time_ms:-0}"
    log "Stall stats from geth.log (graceful close): count=$m_stall_count time=${m_stall_time_ms}ms compaction=${m_compaction_time_ms}ms"
  else
    m_stall_count="${live_stall_count:-0}"
    m_stall_time_ms="${live_stall_time_ms:-0}"
    m_compaction_time_ms="${live_compaction_time_ms:-0}"
    if [[ "${m_stall_count:-0}" -gt 0 ]] 2>/dev/null; then
      log "Stall stats from live HTTP scrape (geth did not close gracefully): count=$m_stall_count"
    else
      log "WARNING: No write stall stats available (geth killed before Close and HTTP scrape failed)"
    fi
  fi
}

# ── Kill all EL+CL processes ─────────────────────────────────────────
kill_el_cl() {
  # Kill Lighthouse VC + BN
  if [ -f "${DIR_LOGS:-/tmp}/lighthouse.pids" ] 2>/dev/null; then
    while read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$DIR_LOGS/lighthouse.pids"
  fi
  sleep 1
  if [ -f "${DIR_LOGS:-/tmp}/lighthouse.pids" ] 2>/dev/null; then
    while read -r pid; do
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done < "$DIR_LOGS/lighthouse.pids"
  fi

  # Graceful geth shutdown: SIGINT → wait up to 30s for Pebble close
  if [[ -n "${CUR_GETH_PID:-}" ]] && kill -0 "$CUR_GETH_PID" 2>/dev/null; then
    kill -INT "$CUR_GETH_PID" 2>/dev/null || true
    local waited=0
    while kill -0 "$CUR_GETH_PID" 2>/dev/null && (( waited < 30 )); do
      sleep 1
      (( ++waited ))
    done
    if kill -0 "$CUR_GETH_PID" 2>/dev/null; then
      log "WARNING: geth did not exit within 30s, sending SIGKILL"
      kill -9 "$CUR_GETH_PID" 2>/dev/null || true
    fi
  fi

  # Fallback: kill stray processes on our ports
  fuser -k 8545/tcp 2>/dev/null || true
  fuser -k "${ENGINE_API_PORT:-8551}/tcp" 2>/dev/null || true
  fuser -k "${BEACON_API_PORT:-5052}/tcp" 2>/dev/null || true
  sleep 1
}

# ── Run a spamoor scenario ────────────────────────────────────────────
# Usage: run_spamoor SCENARIO DURATION_S THROUGHPUT LOG_FILE [PRIVKEY] [EXTRA_ARGS...]
run_spamoor() {
  local scenario="$1"
  local duration_s="$2"
  local throughput="$3"
  local logfile="$4"
  local privkey="${5:-$DEV_PRIVKEY}"
  shift 5 2>/dev/null || shift $#

  local timeout_str
  timeout_str=$(secs_to_duration "$duration_s")

  log "  spamoor $scenario: throughput=$throughput tx/slot, timeout=$timeout_str"

  "$SPAMOOR" "$scenario" \
    -h "http://127.0.0.1:8545" \
    -p "0x${privkey}" \
    --slot-duration "$SLOT_DURATION" \
    --timeout "$timeout_str" \
    --throughput "$throughput" \
    --basefee "$BASEFEE_GWEI" \
    --tipfee "$TIPFEE_GWEI" \
    --refill-amount "$REFILL_ETH" \
    "$@" \
    2>&1 | tee "$logfile"
}

# ── Write metrics.txt ────────────────────────────────────────────────
# Usage: write_metrics FILE label streams mode confirmed_tps confirmed_txs
#        throughput_txb waf bps total_bps block_delta time_delta
#        total_blocks total_time stall_count stall_time_ms compaction_time_ms
#        l0_comp nonl0_comp
write_metrics() {
  cat > "$1" <<EOF
label=$2
streams=$3
mode=$4
confirmed_tps=$5
confirmed_txs=$6
throughput_txb=$7
waf=$8
bps=$9
total_bps=${10}
main_phase_blocks=${11}
main_phase_seconds=${12}
total_blocks=${13}
total_seconds=${14}
stall_count=${15}
stall_time_ms=${16}
compaction_time_ms=${17}
level0_compactions=${18}
non_level0_compactions=${19}
EOF
}

# ── Write human-readable summary ─────────────────────────────────────
write_summary() {
  local rdir="$1" label="$2" streams="$3"
  local m_confirmed_tps="$4" m_confirmed_txs="$5" m_txb="$6"
  local waf_value="$7" m_bps="$8" block_delta="$9" time_delta="${10}"
  local m_stall_count="${11}" m_stall_time_ms="${12}" m_compaction_time_ms="${13}"
  local femu_raw="${14}"

  local stall_time_disp compaction_time_disp
  stall_time_disp=$(python3 -c "ms=int('${m_stall_time_ms:-0}'); print(f'{ms/1000:.1f}s')")
  compaction_time_disp=$(python3 -c "ms=int('${m_compaction_time_ms:-0}'); print(f'{ms/1000:.1f}s')")

  cat > "$rdir/summary.txt" <<EOF
=== Benchmark Round: $label (STREAMS=$streams) ===
Date: $(date)
Mode: $MODE
Workload: EthPandaOps spamoor (official EF benchmark tooling)

--- Primary Metrics (main phase) ---
Confirmed TPS:        $m_confirmed_tps tx/s  ($m_confirmed_txs txs in $block_delta blocks)
Throughput:           $m_txb tx/block  (spamoor 60-block avg)
Blocks/sec:           $m_bps  ($block_delta blocks / ${time_delta}s)
WAF:                  $waf_value
Write Stalls:         $m_stall_count  (total time: $stall_time_disp)
Compaction Time:      $compaction_time_disp

--- FEMU FTL Stats ---
$femu_raw
EOF
}

# ── Print comparison table ────────────────────────────────────────────
print_comparison() {
  local nfdp_file="$1" fdp_file="$2"

  local n_ctps f_ctps n_txb f_txb n_waf f_waf n_bps f_bps
  local n_stalls f_stalls n_stall_ms f_stall_ms n_comp_ms f_comp_ms
  local n_l0 f_l0 n_nl0 f_nl0

  n_ctps=$(load_metric "$nfdp_file" confirmed_tps)
  f_ctps=$(load_metric "$fdp_file" confirmed_tps)
  n_txb=$(load_metric "$nfdp_file" throughput_txb)
  f_txb=$(load_metric "$fdp_file" throughput_txb)
  n_waf=$(load_metric "$nfdp_file" waf)
  f_waf=$(load_metric "$fdp_file" waf)
  n_bps=$(load_metric "$nfdp_file" bps)
  f_bps=$(load_metric "$fdp_file" bps)
  n_stalls=$(load_metric "$nfdp_file" stall_count)
  f_stalls=$(load_metric "$fdp_file" stall_count)
  n_stall_ms=$(load_metric "$nfdp_file" stall_time_ms)
  f_stall_ms=$(load_metric "$fdp_file" stall_time_ms)
  n_comp_ms=$(load_metric "$nfdp_file" compaction_time_ms)
  f_comp_ms=$(load_metric "$fdp_file" compaction_time_ms)
  n_l0=$(load_metric "$nfdp_file" level0_compactions)
  f_l0=$(load_metric "$fdp_file" level0_compactions)
  n_nl0=$(load_metric "$nfdp_file" non_level0_compactions)
  f_nl0=$(load_metric "$fdp_file" non_level0_compactions)

  local n_stall_disp f_stall_disp n_comp_disp f_comp_disp
  n_stall_disp=$(python3 -c "print(f'{int(\"${n_stall_ms:-0}\")/1000:.1f} s')" 2>/dev/null || echo "N/A")
  f_stall_disp=$(python3 -c "print(f'{int(\"${f_stall_ms:-0}\")/1000:.1f} s')" 2>/dev/null || echo "N/A")
  n_comp_disp=$(python3 -c "print(f'{int(\"${n_comp_ms:-0}\")/1000:.1f} s')" 2>/dev/null || echo "N/A")
  f_comp_disp=$(python3 -c "print(f'{int(\"${f_comp_ms:-0}\")/1000:.1f} s')" 2>/dev/null || echo "N/A")

  local d_ctps d_txb d_waf d_bps d_stalls d_stall_time d_comp_time d_l0 d_nl0
  d_ctps=$(pct_change "$n_ctps" "$f_ctps")
  d_txb=$(pct_change "$n_txb" "$f_txb")
  d_waf=$(pct_change "$n_waf" "$f_waf")
  d_bps=$(pct_change "$n_bps" "$f_bps")
  d_stalls=$(pct_change "$n_stalls" "$f_stalls")
  d_stall_time=$(pct_change "$n_stall_ms" "$f_stall_ms")
  d_comp_time=$(pct_change "$n_comp_ms" "$f_comp_ms")
  d_l0=$(pct_change "$n_l0" "$f_l0")
  d_nl0=$(pct_change "$n_nl0" "$f_nl0")

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════"
  echo "              Non-FDP (1 PID)  vs  FDP (8 PIDs) Comparison"
  echo "═══════════════════════════════════════════════════════════════════════"
  printf "  %-22s %12s %12s %12s\n" "Metric" "Non-FDP" "FDP" "Delta"
  echo "───────────────────────────────────────────────────────────────────────"
  printf "  %-22s %12s %12s %12s\n" "Confirmed TPS (tx/s)" "$n_ctps"    "$f_ctps"    "$d_ctps"
  printf "  %-22s %12s %12s %12s\n" "Throughput (tx/block)" "$n_txb"    "$f_txb"     "$d_txb"
  printf "  %-22s %12s %12s %12s\n" "WAF"                   "$n_waf"    "$f_waf"     "$d_waf"
  printf "  %-22s %12s %12s %12s\n" "Blocks/sec"            "$n_bps"    "$f_bps"     "$d_bps"
  printf "  %-22s %12s %12s %12s\n" "Write Stalls"          "$n_stalls" "$f_stalls"  "$d_stalls"
  printf "  %-22s %12s %12s %12s\n" "Write Stall Time"      "$n_stall_disp" "$f_stall_disp" "$d_stall_time"
  printf "  %-22s %12s %12s %12s\n" "Compaction Time"       "$n_comp_disp"  "$f_comp_disp"  "$d_comp_time"
  printf "  %-22s %12s %12s %12s\n" "L0 Compactions"        "$n_l0"     "$f_l0"      "$d_l0"
  printf "  %-22s %12s %12s %12s\n" "Non-L0 Compactions"    "$n_nl0"    "$f_nl0"     "$d_nl0"
  echo "───────────────────────────────────────────────────────────────────────"
  echo "  Mode: $MODE   Workload: spamoor (EthPandaOps)   Slot time: 4s"
  echo "  For Confirmed TPS, Throughput & Blocks/sec: positive delta = FDP is better"
  echo "  For WAF, Stalls & Compaction Time:          negative delta = FDP is better"
  echo "═══════════════════════════════════════════════════════════════════════"
  echo ""
}
