# FDP Benchmark Suite

Benchmarks for **NVMe Flexible Data Placement (FDP)** on blockchain
databases, running on an FEMU-emulated SSD with F2FS.

## Directory Structure

```
fdp-scripts/
├── common/                         # Shared infrastructure
│   ├── env.sh                      # Device paths, mount, SSH, fdp_stats, helpers
│   ├── fdp_stats                   # FEMU FTL stats binary
│   └── fdp_stats.cc                # Source
│
├── eth-bench/                      # Ethereum benchmarks
│   ├── README.md                   # Full documentation
│   ├── era1/                       # Downloaded Era1 archives
│   ├── results/                    # Benchmark output (non-fdp/, fdp/)
│   └── scripts/
│       ├── bench.sh                # Mainnet replay benchmark (chunked pipeline)
│       ├── env.sh                  # Ethereum-specific config + PID mapping
│       ├── helpers.sh              # Ethereum helper functions
│       ├── run_geth.sh             # Start geth EL
│       ├── run_lighthouse.sh       # Start Lighthouse CL
│       ├── gen_genesis.sh          # Generate genesis files
│       └── setup_testnet.sh        # One-time setup
│
├── sui-bench/                      # Sui benchmarks
│   ├── README.md                   # Full documentation
│   ├── move/                       # io_churn Move contract
│   ├── src/                        # Rust SDK benchmark (main.rs)
│   └── scripts/
│       ├── bench.sh                # SDK-based benchmark
│       └── env.sh                  # Sui-specific config
│
├── f2fs-tools-fdp/                 # mkfs.f2fs + fdp_f2fs_mount (FDP-aware mount)
└── fdp_stats / fdp_stats.cc        # Original fdp_stats (also copied to common/)
```

## Benchmark Modes

### 1. Ethereum Mainnet Replay (`bench.sh`)
Replays real mainnet blocks (0 – 2.45 M) through `geth import` for full
EVM re-execution, following the methodology of LVMT (OSDI '23), Ethanos
(EuroSys '21), and LMPTs (IEEE ICBC '22). Blocks are downloaded as
Era1 archives from `era1.ethportal.net`, converted to RLP by `era2rlp`,
and imported in 500 K-block chunks to keep host disk usage bounded.

### 2. Sui Synthetic Workload (`bench.sh`)
SDK-based benchmark using `sui-single-node-benchmark` with a custom
`io_churn` Move contract (mixed CREATE/UPDATE workload). Uses
`ValidatorWithFakeConsensus` for single-node operation.

**Sui replay status**: `sui-tool replay` uses in-memory storage only
(no RocksDB writes) — unsuitable for I/O benchmarking.

## FDP Stream Allocation (4-Tier Pebble VFS)

Geth's Pebble database uses a custom **FDP-aware VFS** that routes SST
files into separate directories based on their write temperature. Each
directory maps to a different NVMe Placement ID (PID) via F2FS FDP.

| PID | Directory    | Temp    | Content                          |
|-----|-------------|---------|----------------------------------|
| p0  | wal/        | HOTTEST | EL Pebble WAL (write buffer)     |
| p1  | sst_flush/  | HOT     | EL Pebble flush L0 SSTs (fresh)  |
| p2  | sst_l0cmp/  | WARM    | EL Pebble L0→Lbase compaction    |
| p3  | sst_midcmp/ | COOL    | EL Pebble mid-level compaction   |
| p4  | chaindata/  | COLD    | EL Pebble deep/stable SSTs       |
| p5  | ancient/    | COLDEST | EL frozen blocks (ancient)       |
| p6  | cl_hot/     | HOT     | CL Lighthouse hot DB             |
| p7  | cl_cold/    | COOL    | CL Lighthouse freezer DB         |

The 4-tier classification in Pebble (`pebble_fdp.go`):
- **Tier 0 — Flush** (PID 1): Memtable flush → L0 SSTs
- **Tier 1 — L0 compaction** (PID 2): L0→Lbase compaction output
- **Tier 2 — Mid-level compaction** (PID 3): Output level < 6
- **Tier 3 — Deep/stable** (PID 4): Output level ≥ 6 (stays in chaindata)

Non-FDP mode: all PIDs collapse to p0 (single stream, `fdp_log_n=1`).

## Quick Start

```bash
# Ethereum mainnet replay  (download → convert → import, all in one)
cd eth-bench && ./scripts/bench.sh bench

# Download era1 separately (if you want to inspect files)
cd eth-bench && ./scripts/bench.sh download 0 3200000

# Sui SDK benchmark
cd sui-bench && ./scripts/bench.sh
```

## Hardware

- **FEMU SSD**: 64 GB, 8ch×8LUN, 16 MB NAND blocks, 98 flash lines,
  `gc_thres_pcent=75` (default), `gc_thres_pcent_high=95`, 1 RG, 8 handles
- **F2FS + FDP**: 8 NVMe placement IDs (p0–p7), `fdp_log_n=8` (FDP) / `1` (non-FDP)
- **Geth**: v1.14.8 with FDP-aware Pebble VFS (4-tier SST routing)
- **Pebble**: v1.1.5, SST compression disabled, 16 MB memtable, snapshots off
- **Sui**: Fork with hybrid-semantic FDP RocksDB patches (per-CF + per-DB routing)
