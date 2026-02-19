#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Start Lighthouse (CL) — beacon node + validator client
# ═══════════════════════════════════════════════════════════════════════
#
# Lighthouse drives block production via the Engine API to geth.
# Block timing: 12-second slots (mainnet-equivalent).
#
# FDP placement:
#   p4/cl_hot/     Lighthouse hot DB  (chain_db, recent states)  — HOT
#   p5/cl_cold/    Lighthouse freezer  (finalized state diffs)   — COOL
#   p7/cl_vc/      Validator client  (slashing protection DB)    — COLDEST
#   p7/logs/       BN + VC log files                             — COLDEST
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/helpers.sh"

# ── Validate prerequisites ────────────────────────────────────────────
if [ ! -x "$LIGHTHOUSE_BIN" ]; then
  log "ERROR: Lighthouse not found at $LIGHTHOUSE_BIN"
  log "       Run setup_testnet.sh first."
  exit 1
fi

for f in "$TESTNET_DIR/config.yaml" "$TESTNET_DIR/genesis.ssz"; do
  if [ ! -f "$f" ]; then
    log "ERROR: $f missing. Run gen_genesis.sh first."
    exit 1
  fi
done

if [ ! -f "$JWT_SECRET" ]; then
  log "ERROR: JWT secret not found at $JWT_SECRET"
  log "       Start geth first (run_geth.sh generates it)."
  exit 1
fi

# ── Prepare directories ──────────────────────────────────────────────
mkdir -p "$DIR_CL_HOT" "$DIR_CL_COLD" "$DIR_CL_VC" "$DIR_LOGS"

# ── Prepare validator keystores ──────────────────────────────────────
# Copy validator keys to the VC datadir if not already present.
# Lighthouse VC expects:  validators/<pubkey>/voting-keystore.json
#                         secrets/<pubkey>
KEYS_SRC="$TESTNET_DIR/validator_keys"
VC_VALIDATORS="$DIR_CL_VC/validators"
VC_SECRETS="$DIR_CL_VC/secrets"

if [ -d "$KEYS_SRC/keys" ] && [ ! -d "$VC_VALIDATORS" ]; then
  log "Copying validator keys to VC datadir ..."
  mkdir -p "$VC_VALIDATORS" "$VC_SECRETS"
  cp -r "$KEYS_SRC/keys/"* "$VC_VALIDATORS/" 2>/dev/null || true
  cp -r "$KEYS_SRC/secrets/"* "$VC_SECRETS/" 2>/dev/null || true
  NUM_VALS=$(ls "$VC_VALIDATORS" 2>/dev/null | wc -l)
  log "Prepared $NUM_VALS validators"
elif [ -d "$VC_VALIDATORS" ]; then
  NUM_VALS=$(ls "$VC_VALIDATORS" 2>/dev/null | wc -l)
  log "Validator keys already in place ($NUM_VALS validators)"
else
  log "WARNING: No validator keys found in $KEYS_SRC"
  log "         Run setup_testnet.sh to generate them."
fi

# ── Log FDP layout ───────────────────────────────────────────────────
log "Launching Lighthouse with FDP data placement"
log "  Hot DB     → $PID_CL_HOT  ($DIR_CL_HOT)"
log "  Cold DB    → $PID_CL_COLD ($DIR_CL_COLD)"
log "  Validator  → $PID_META    ($DIR_CL_VC)"
log "  Engine API → $ENGINE_API_URL"
log "  JWT secret → $JWT_SECRET"

# ── Start Beacon Node ────────────────────────────────────────────────
# Use setsid -f to run in a new session so that terminal SIGHUP
# (e.g. from SSH disconnect) cannot reach lighthouse.  Lighthouse's
# Rust/tokio runtime explicitly installs a SIGHUP handler (overriding
# the SIG_IGN inherited from nohup), so session isolation is the only
# reliable protection.
log "Starting beacon node ..."
setsid -f "$LIGHTHOUSE_BIN" beacon_node \
  --testnet-dir "$TESTNET_DIR" \
  --datadir "$DIR_CL_HOT" \
  --freezer-dir "$DIR_CL_COLD" \
  --execution-endpoint "$ENGINE_API_URL" \
  --execution-jwt "$JWT_SECRET" \
  --staking \
  --http-address 0.0.0.0 \
  --http-port "$BEACON_API_PORT" \
  --enr-address 127.0.0.1 \
  --listen-address 0.0.0.0 \
  --port 9000 \
  --target-peers 0 \
  --disable-packet-filter \
  --enable-private-discovery \
  --allow-insecure-genesis-sync \
  --disable-upnp \
  --disable-quic \
  --epochs-per-migration 1 \
  --debug-level info \
  --logfile-dir "$DIR_LOGS" \
  --logfile-max-number 3 \
  > "$DIR_LOGS/lighthouse_bn.log" 2>&1
# setsid -f forks; find the actual lighthouse PID via pgrep
sleep 1
BN_PID=$(pgrep -f "lighthouse.*beacon_node.*--datadir" | head -1)
if [[ -z "$BN_PID" ]]; then
  log "ERROR: Beacon node failed to start"
  tail -20 "$DIR_LOGS/lighthouse_bn.log" 2>/dev/null || true
  exit 1
fi
log "Beacon node started (PID=$BN_PID, session-isolated)"

# ── Wait for beacon API ──────────────────────────────────────────────
log "Waiting for beacon API at $BEACON_API_URL ..."
for i in $(seq 1 60); do
  if curl -sf "$BEACON_API_URL/eth/v1/node/health" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$BN_PID" 2>/dev/null; then
    log "ERROR: Beacon node exited unexpectedly"
    tail -20 "$DIR_LOGS/lighthouse_bn.log" 2>/dev/null || true
    exit 1
  fi
  sleep 1
  if [ "$i" -eq 60 ]; then
    log "ERROR: Beacon API not up after 60s"
    tail -20 "$DIR_LOGS/lighthouse_bn.log" 2>/dev/null || true
    exit 1
  fi
done
log "Beacon API is up"

# ── Start Validator Client ───────────────────────────────────────────
log "Starting validator client ..."
setsid -f "$LIGHTHOUSE_BIN" validator_client \
  --testnet-dir "$TESTNET_DIR" \
  --datadir "$DIR_CL_VC" \
  --beacon-nodes "$BEACON_API_URL" \
  --suggested-fee-recipient "$DEV_ADDRESS" \
  --init-slashing-protection \
  --debug-level info \
  --logfile-dir "$DIR_LOGS" \
  > "$DIR_LOGS/lighthouse_vc.log" 2>&1
sleep 1
VC_PID=$(pgrep -f "lighthouse.*validator_client" | head -1)
if [[ -z "$VC_PID" ]]; then
  log "ERROR: Validator client failed to start"
  tail -20 "$DIR_LOGS/lighthouse_vc.log" 2>/dev/null || true
  exit 1
fi
log "Validator client started (PID=$VC_PID, session-isolated)"

# ── Output PIDs for bench.sh to track ────────────────────────────────
# Write PIDs to a file so bench.sh can kill them during cleanup.
PIDFILE="$DIR_LOGS/lighthouse.pids"
echo "$BN_PID" > "$PIDFILE"
echo "$VC_PID" >> "$PIDFILE"
log "PIDs written to $PIDFILE (BN=$BN_PID, VC=$VC_PID)"

# ── Wait for first proposed block ────────────────────────────────────
log "Waiting for first CL-proposed block ..."
for i in $(seq 1 120); do
  BLOCK_NUM=$(curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://127.0.0.1:8545 2>/dev/null | \
    python3 -c 'import sys,json; r=json.load(sys.stdin); print(int(r["result"],16))' 2>/dev/null || echo "0")
  if [ "$BLOCK_NUM" -gt 0 ] 2>/dev/null; then
    log "First block detected! blockNumber=$BLOCK_NUM"
    break
  fi
  sleep 1
  if [ "$i" -eq 120 ]; then
    log "WARNING: No blocks after 120s (expected first slot at ~12s)"
    log "         Check $DIR_LOGS/lighthouse_bn.log for errors"
  fi
done

log "Lighthouse (BN + VC) running"
