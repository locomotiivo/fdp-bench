# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## About This Repository

This is a research/experimental fork of Aptos focused on evaluating Aptos performance.

**Base:** aptos-core - blockchain for performance
**Research Focus:** evaluting throughput with tail latencies(us) of transaction(p10,p20,p30,p40,p50,p60,p70,p75,p80,p90,p95,p99.p99.9,p99.99,p99.999)
do not use mutex(lock) as possible, please record tail lantencies of each thread and aggreagate at the print phase of workload.


**Code Markers:** `//sj` (researcher implementations), `// FEAT` (feature additions)



## Benchmark Commands(Running Experiments)
i am running on this aptos-core with script:
./testsuite/performance_benchmark_sj.sh --sj
i am running this script on remote server, not here. do not execute python or cargo(rust) compile in here. i will test it on server, and give any error message.


i like to print how many block are created during benchmark like below format:
Block generation during benchmark: slot 72 to 2930 = 2859 blocks

## Current result of benchmark (./testsuite/performance_benchmark_sj.sh --sj)
