# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## About This Repository

This is a research/experimental fork of solana focused on evaluating solana performance.

**Base:** solana - blockchain for performance
**Research Focus:** evaluting throughput with tail latencies(us) of transaction(p10,p20,p30,p40,p50,p60,p70,p75,p80,p90,p95,p99.p99.9,p99.99,p99.999)
do not use mutex(lock) as possible, please record tail lantencies of each thread and aggreagate at the print phase of workload.


**Code Markers:** `//sj` (researcher implementations), `// FEAT` (feature additions)



## Benchmark Commands(Running Experiments)
i am running on this solana-bench-tps with script:
NDEBUG=1 /home/femu/solana/multinode-demo/bench-tps-tenant0-1000sec.sh
i am running this script on remote server, not here. do not execute python or cargo(rust) compile in here. i will test it on server, and give any error message.

***do not compile here***

## solana config
femu@fvm:~/solana$ solana config get
Config File: /home/femu/.config/solana/cli/config.yml
RPC URL: http://localhost:8899 
WebSocket URL: ws://localhost:8900/ (computed)
Keypair Path: /home/femu/vote-account.json 
Commitment: confirmed 
femu@fvm:~/solana$ 


## Current result of benchmark (./testsuite/performance_benchmark_sj.sh --sj)


