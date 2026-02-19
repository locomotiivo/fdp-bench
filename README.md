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
│   └── scripts/
│       ├── bench.sh                # Synthetic workload (spamoor-based, Geth+Lighthouse)
│       ├── replay.sh               # Mainnet block replay (geth import, full EVM re-exec)
│       ├── env.sh                  # Ethereum-specific config
│       ├── helpers.sh              # Ethereum helper functions
│       ├── run_geth.sh             # Start geth EL
│       ├── run_lighthouse.sh       # Start Lighthouse CL
│       ├── gen_genesis.sh          # Generate genesis files
│       └── setup_testnet.sh        # One-time setup
│
├── sui-bench/                      # Sui benchmarks
│   └── scripts/
│       ├── bench.sh                # Synthetic workload (sui-single-node-benchmark)
│       └── env.sh                  # Sui-specific config
│
├── f2fs-tools-fdp/                 # mkfs.f2fs + fdp_f2fs_mount (FDP-aware mount)
└── fdp_stats / fdp_stats.cc        # Original fdp_stats (also copied to common/)
```

## Benchmark Modes

### 1. Synthetic Workload (`bench.sh`)
- **Ethereum**: Post-merge testnet with spamoor transaction generators.
  Three phases: seed (storagespam), DeFi (uniswap), burst (erc20).
- **Sui**: sui-single-node-benchmark with PTB workloads (transfers,
  mints, dynamic fields). Uses `ValidatorWithFakeConsensus` component.

### 2. Mainnet Replay (`replay.sh`, Ethereum only)
Replays real mainnet blocks through `geth import` for full EVM
re-execution, following the methodology of LVMT (OSDI '23), Ethanos
(EuroSys '21), and LMPTs (IEEE ICBC '22).

**Sui replay status**: `sui-tool replay` uses in-memory storage only
(no RocksDB writes) — unsuitable for I/O benchmarking. The synthetic
`sui-single-node-benchmark` remains the only viable approach for Sui
FDP measurement on a resource-constrained SSD.

## Quick Start

```bash
# Ethereum synthetic benchmark
cd eth-bench && ./scripts/bench.sh

# Ethereum mainnet replay
cd eth-bench && ./scripts/replay.sh download 0 600000
cd eth-bench && ./scripts/replay.sh convert
cd eth-bench && ./scripts/replay.sh bench

# Sui synthetic benchmark
cd sui-bench && ./scripts/bench.sh
```

## Hardware

- **FEMU SSD**: 106 GB, 8ch×8LUN, `gc_thres_pcent=75%`
- **F2FS + FDP**: 8 NVMe placement IDs (p0-p7)
- **Geth**: v1.16.8 with FDP-aware Pebble VFS patches
- **Sui**: Fork with FDP-aware RocksDB patches
