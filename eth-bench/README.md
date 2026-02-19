# FDP Ethereum Benchmark

Measures the impact of NVMe **Flexible Data Placement (FDP)** on Ethereum
execution-layer performance by replaying real mainnet blocks through
`geth import` (full EVM re-execution), following the methodology of
LVMT (OSDI '23), Ethanos (EuroSys '21), and LMPTs (IEEE ICBC '22).

## Quick Start

```bash
# Run full FDP vs non-FDP mainnet replay comparison
./scripts/bench.sh bench

# Or download → convert → import in one shot
./scripts/bench.sh download 0 3200000   # fetch Era1 archives
./scripts/bench.sh convert              # era1 → RLP (per chunk)
./scripts/bench.sh bench                # run both modes
```

## Directory Structure

```
eth-bench/
├── README.md                  # This file
├── era1/                      # Downloaded Era1 archives (306 files, blocks 0-2.5M)
├── results/                   # Benchmark output
│   ├── non-fdp/               # metrics.txt, summary.txt, monitor.log, import.log
│   ├── fdp/                   # Same structure
│   └── plot_waf.py            # WAF over time comparison graph
├── scripts/
│   ├── bench.sh               # Mainnet replay benchmark (chunked pipeline)
│   ├── env.sh                 # Ethereum-specific config (PID mapping, paths)
│   ├── helpers.sh             # Shared functions (parsing, metrics, lifecycle)
│   ├── run_geth.sh            # Start geth (EL) with FDP-aware Pebble
│   ├── run_lighthouse.sh      # Start Lighthouse (CL) beacon + validator
│   ├── gen_genesis.sh         # Generate EL genesis.json + CL genesis.ssz
│   └── setup_testnet.sh       # One-time: install binaries + gen validator keys
└── testnet/                   # CL config, genesis, validator keystores
```

Shared infra lives one level up:
```
fdp-scripts/
├── common/
│   ├── env.sh                 # Device paths, mount, SSH, fdp_stats
│   ├── fdp_stats              # FEMU FTL stats binary
│   └── fdp_stats.cc           # Source
├── f2fs-tools-fdp/            # mkfs.f2fs + fdp_f2fs_mount
├── eth-bench/                 # ← you are here
└── sui-bench/
```

## Methodology

### Mainnet Block Replay

Real Ethereum mainnet blocks are replayed through `geth import`, which
fully re-executes every transaction through the EVM and writes all state
transitions to Pebble. This provides:

1. **Real state growth** — Ethereum's actual account/storage distribution
2. **Academic comparability** — Same methodology as published results
3. **Natural GC onset** — Continuous state growth fills the SSD

### Chunked Pipeline

Blocks are processed in **500 K-block chunks** to keep host disk usage
bounded (era1 + RLP for each chunk fits on the 85 GB host disk):

1. **Download**: `geth download-era` fetches Era1 archives (8192-block
   epochs) from `era1.ethportal.net` with embedded SHA256 verification
2. **Convert**: `era2rlp` (custom Go tool) reads Era1 files and outputs
   concatenated RLP — the format `geth import` expects
3. **Import**: `geth import blocks.rlp` re-executes all transactions,
   writing state to Pebble. Temporary RLP is deleted after each chunk.
4. **Monitor**: Background thread snapshots FEMU FTL stats every 5 min

### Block Range

Default: **3,200,000 blocks** (7 chunks of 500 K).

- Blocks 0–2 M import fast (~65 min), consuming ~42 of 98 flash lines
- Blocks 2 M–2.42 M import slowly (state trie complexity)
- With `gc_thres_pcent=75` (default), GC onset at ~74 lines ≈ block 2.84 M
- WAF climbs rapidly after GC onset
- 3.2 M gives ~30+ min of sustained GC after onset

### Pebble Configuration

| Parameter | Value | Justification |
|-----------|-------|---------------|
| SST compression | off (`GETH_PEBBLE_NO_COMPRESSION=1`) | Deterministic WAF, faster SSD fill |
| Memtable size | 16 MB (`GETH_PEBBLE_MEMTABLE_MB=16`) | Resource-constrained model |
| State snapshots | disabled (`--state.scheme=hash`) | Forces reads through MPT on disk |
| Cache | 2048 MB | Fits in 16 GB VM RAM |

## FDP Stream Allocation (4-Tier Pebble VFS)

The custom FDP VFS (`pebble_fdp.go`) intercepts SST file creation and
routes files to separate directories based on their write temperature.
Tier classification uses Pebble's `CompactionBegin` callback to inspect
the compaction input and output levels.

| PID | Directory    | Temp    | Content                          |
|-----|-------------|---------|----------------------------------|
| p0  | wal/        | HOTTEST | Pebble WAL (write buffer)        |
| p1  | sst_flush/  | HOT     | Flush L0 SSTs (memtable → disk)  |
| p2  | sst_l0cmp/  | WARM    | L0→Lbase compaction output       |
| p3  | sst_midcmp/ | COOL    | Mid-level compaction (out < L6)  |
| p4  | chaindata/  | COLD    | Deep/stable SSTs (out ≥ L6)      |
| p5  | ancient/    | COLDEST | Frozen block archive (ancient)   |
| p6  | cl_hot/     | HOT     | Lighthouse hot DB                |
| p7  | cl_cold/    | COOL    | Lighthouse freezer DB            |

### Tier Classification Logic

```
Flush callback         → Tier 0 (PID 1: sst_flush/)
CompactionBegin:
  Input[0].Level == 0  → Tier 1 (PID 2: sst_l0cmp/)
  Output.Level < 6     → Tier 2 (PID 3: sst_midcmp/)
  Output.Level ≥ 6     → Tier 3 (PID 4: chaindata/ — default dir)
```

Non-FDP mode: all PIDs collapse to p0 (`fdp_log_n=1`, single stream).

## Metrics Collected

- **WAF** — Write Amplification Factor (from FEMU FTL counters)
- **Blocks/sec** — Import throughput
- **Mgas/sec** — Gas execution rate (total gas / wall time)
- **Write Stalls** — Pebble stall count & duration
- **Compaction Time** — Total Pebble compaction wall-clock time
- **L0 / Non-L0 Compactions** — Compaction event counts
- **Per-PID Disk Usage** — F2FS directory sizes per placement ID
- **FDP Tier Stats** — SSTs created per tier (flush, L0cmp, midcmp, deep)

## Results (2.45 M Blocks, gc_thres_pcent=60)

Baseline results with lowered GC threshold for faster onset:

| Metric | Non-FDP | FDP | Change |
|--------|---------|-----|--------|
| WAF | 4.74 | 2.41 | **−49.2%** |
| Compaction time | 2590 s | 1692 s | −34.7% |
| Blocks/sec | 191.96 | 202.21 | +5.3% |
| Mgas/sec | 34.19 | 36.01 | +5.3% |
| Write stalls | 0 | 0 | — |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TOTAL_BLOCKS` | 3200000 | Total blocks to replay |
| `CHUNK_BLOCKS` | 500000 | Blocks per download/convert/import chunk |
| `CACHE_MB` | 2048 | Geth cache size in MB |
| `MONITOR_INTERVAL` | 300 | Seconds between FEMU stat snapshots |
| `GETH_BIN` | `~/go-ethereum/build/bin/geth` | Geth binary path |
| `ERA_SERVER` | `https://era1.ethportal.net` | Era1 download server |
| `GETH_FDP_WAL_DIR` | (auto) | Pebble WAL directory |
| `GETH_FDP_FLUSH_DIR` | (auto) | Pebble flush SST directory |
| `GETH_FDP_L0CMP_DIR` | (auto) | Pebble L0 compaction SST directory |
| `GETH_FDP_MIDCMP_DIR` | (auto) | Pebble mid-level compaction SST directory |
