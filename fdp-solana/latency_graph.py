#!/usr/bin/env python3
"""
Read slot_latency_timeseries.csv and generate PDF latency graphs.
Usage:
    python3 latency_graph.py [csv_file] [output_prefix]
    python3 latency_graph.py slot_latency_timeseries.csv bench1
    python3 latency_graph.py  # defaults: slot_latency_timeseries.csv, slot_latency
"""
#sj

import sys
import csv
import os

import matplotlib
matplotlib.use('Agg')  # headless
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

def read_csv(path):
    data = {
        'time_s': [], 'n': [],
        'avg_ms': [], 'p50_ms': [], 'p95_ms': [],
        'p99_ms': [], 'p99.9_ms': [], 'p99.99_ms': []
    }
    with open(path, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            data['time_s'].append(int(row['time_s']))
            data['n'].append(int(row['n']))
            data['avg_ms'].append(float(row['avg_ms']))
            data['p50_ms'].append(float(row['p50_ms']))
            data['p95_ms'].append(float(row['p95_ms']))
            data['p99_ms'].append(float(row['p99_ms']))
            data['p99.9_ms'].append(float(row['p99.9_ms']))
            data['p99.99_ms'].append(float(row['p99.99_ms']))
    return data


def plot_combined(data, output_path):
    """All latency percentiles on one graph."""
    fig, ax = plt.subplots(figsize=(12, 5))
    t = data['time_s']

    ax.plot(t, data['avg_ms'],    label='avg',    linewidth=1.2)
    ax.plot(t, data['p50_ms'],    label='p50',    linewidth=1.2)
    ax.plot(t, data['p95_ms'],    label='p95',    linewidth=1.0, linestyle='--')
    ax.plot(t, data['p99_ms'],    label='p99',    linewidth=1.0, linestyle='--')
    ax.plot(t, data['p99.9_ms'],  label='p99.9',  linewidth=0.8, linestyle=':')
    ax.plot(t, data['p99.99_ms'], label='p99.99', linewidth=0.8, linestyle=':')

    ax.set_xlabel('Time (s)')
    ax.set_ylabel('Latency (ms)')
    ax.set_title('Per-TX Slot Latency (per-second intervals)')
    ax.legend(loc='upper right', fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(output_path, dpi=150)
    plt.close(fig)
    print(f"  -> {output_path}")


def plot_individual(data, metric_key, label, output_path):
    """Single metric graph."""
    fig, ax = plt.subplots(figsize=(10, 4))
    t = data['time_s']

    ax.plot(t, data[metric_key], label=label, linewidth=1.2, color='tab:blue')
    ax.fill_between(t, 0, data[metric_key], alpha=0.1, color='tab:blue')

    ax.set_xlabel('Time (s)')
    ax.set_ylabel('Latency (ms)')
    ax.set_title(f'{label} Latency over Time')
    ax.legend(loc='upper right', fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(output_path, dpi=150)
    plt.close(fig)
    print(f"  -> {output_path}")


def plot_throughput(data, output_path):
    """Confirmed TX count per second."""
    fig, ax = plt.subplots(figsize=(10, 4))
    t = data['time_s']

    ax.bar(t, data['n'], width=0.8, color='tab:green', alpha=0.7, label='confirmed txs/s')

    ax.set_xlabel('Time (s)')
    ax.set_ylabel('Confirmed TXs')
    ax.set_title('Confirmed Transactions per Second')
    ax.legend(loc='upper right', fontsize=9)
    ax.grid(True, alpha=0.3, axis='y')
    fig.tight_layout()
    fig.savefig(output_path, dpi=150)
    plt.close(fig)
    print(f"  -> {output_path}")


def main():
    csv_path = sys.argv[1] if len(sys.argv) > 1 else 'slot_latency_timeseries.csv'
    prefix = sys.argv[2] if len(sys.argv) > 2 else 'slot_latency'

    if not os.path.exists(csv_path):
        print(f"Error: {csv_path} not found")
        sys.exit(1)

    data = read_csv(csv_path)
    n_rows = len(data['time_s'])
    print(f"Read {n_rows} rows from {csv_path}")

    if n_rows == 0:
        print("No data to plot")
        sys.exit(0)

    # 1) Combined graph (all percentiles)
    plot_combined(data, f'{prefix}_combined.pdf')

    # 2) Individual per-metric graphs
    metrics = [
        ('avg_ms',    'Average'),
        ('p50_ms',    'P50'),
        ('p95_ms',    'P95'),
        ('p99_ms',    'P99'),
        ('p99.9_ms',  'P99.9'),
        ('p99.99_ms', 'P99.99'),
    ]
    for key, label in metrics:
        plot_individual(data, key, label, f'{prefix}_{label.lower()}.pdf')

    # 3) Throughput graph
    plot_throughput(data, f'{prefix}_throughput.pdf')

    print(f"\nDone. Generated {2 + len(metrics)} PDF files with prefix '{prefix}_'")


if __name__ == '__main__':
    main()
