"""
Generate benchmark comparison charts from CSV results.

Run this script locally or in a notebook to generate charts.
"""

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

# Load the data
data = {
    'model_type': ['subprocess', 'subprocess', 'subprocess', 'rpy2', 'rpy2', 'rpy2'],
    'batch_size': [10, 25, 50, 10, 25, 50],
    'avg_ms': [2311.78, 2051.00, 2038.80, 1118.40, 995.58, 914.41],
    'min_ms': [1962.33, 1932.31, 2024.09, 871.23, 919.98, 843.48],
    'max_ms': [3031.84, 2228.31, 2053.52, 1336.11, 1070.47, 985.35],
    'p50_ms': [2252.67, 2021.69, 2038.80, 1163.71, 995.94, 914.41],
    'p95_ms': [2840.10, 2198.13, 2052.05, 1312.72, 1061.01, 978.26],
    'throughput': [4.33, 12.19, 24.52, 8.94, 25.11, 54.68],
    'std_ms': [344.14, 108.75, 14.71, 157.99, 53.82, 70.94]
}

df = pd.DataFrame(data)

# Set up the figure with subplots
fig, axes = plt.subplots(2, 2, figsize=(14, 10))
fig.suptitle('R Model Inference: Subprocess vs rpy2 Performance Comparison', fontsize=14, fontweight='bold')

# Colors
colors = {'subprocess': '#E74C3C', 'rpy2': '#27AE60'}
batch_sizes = [10, 25, 50]
x = np.arange(len(batch_sizes))
width = 0.35

# Plot 1: Average Response Time
ax1 = axes[0, 0]
subprocess_avg = df[df['model_type'] == 'subprocess']['avg_ms'].values
rpy2_avg = df[df['model_type'] == 'rpy2']['avg_ms'].values

bars1 = ax1.bar(x - width/2, subprocess_avg, width, label='Subprocess', color=colors['subprocess'])
bars2 = ax1.bar(x + width/2, rpy2_avg, width, label='rpy2', color=colors['rpy2'])

ax1.set_xlabel('Batch Size (rows)')
ax1.set_ylabel('Average Response Time (ms)')
ax1.set_title('Average Response Time by Batch Size')
ax1.set_xticks(x)
ax1.set_xticklabels(batch_sizes)
ax1.legend()
ax1.grid(axis='y', alpha=0.3)

# Add value labels
for bar in bars1:
    ax1.annotate(f'{bar.get_height():.0f}',
                xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                xytext=(0, 3), textcoords='offset points',
                ha='center', va='bottom', fontsize=9)
for bar in bars2:
    ax1.annotate(f'{bar.get_height():.0f}',
                xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                xytext=(0, 3), textcoords='offset points',
                ha='center', va='bottom', fontsize=9)

# Plot 2: Throughput
ax2 = axes[0, 1]
subprocess_tp = df[df['model_type'] == 'subprocess']['throughput'].values
rpy2_tp = df[df['model_type'] == 'rpy2']['throughput'].values

bars1 = ax2.bar(x - width/2, subprocess_tp, width, label='Subprocess', color=colors['subprocess'])
bars2 = ax2.bar(x + width/2, rpy2_tp, width, label='rpy2', color=colors['rpy2'])

ax2.set_xlabel('Batch Size (rows)')
ax2.set_ylabel('Throughput (rows/second)')
ax2.set_title('Throughput by Batch Size')
ax2.set_xticks(x)
ax2.set_xticklabels(batch_sizes)
ax2.legend()
ax2.grid(axis='y', alpha=0.3)

for bar in bars1:
    ax2.annotate(f'{bar.get_height():.1f}',
                xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                xytext=(0, 3), textcoords='offset points',
                ha='center', va='bottom', fontsize=9)
for bar in bars2:
    ax2.annotate(f'{bar.get_height():.1f}',
                xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                xytext=(0, 3), textcoords='offset points',
                ha='center', va='bottom', fontsize=9)

# Plot 3: Response Time Range (Min/Max with error bars)
ax3 = axes[1, 0]
subprocess_min = df[df['model_type'] == 'subprocess']['min_ms'].values
subprocess_max = df[df['model_type'] == 'subprocess']['max_ms'].values
rpy2_min = df[df['model_type'] == 'rpy2']['min_ms'].values
rpy2_max = df[df['model_type'] == 'rpy2']['max_ms'].values

# Calculate error bar heights
subprocess_err = [subprocess_avg - subprocess_min, subprocess_max - subprocess_avg]
rpy2_err = [rpy2_avg - rpy2_min, rpy2_max - rpy2_avg]

ax3.errorbar(x - width/2, subprocess_avg, yerr=subprocess_err, fmt='o', 
             color=colors['subprocess'], capsize=5, capthick=2, markersize=8, label='Subprocess')
ax3.errorbar(x + width/2, rpy2_avg, yerr=rpy2_err, fmt='o', 
             color=colors['rpy2'], capsize=5, capthick=2, markersize=8, label='rpy2')

ax3.set_xlabel('Batch Size (rows)')
ax3.set_ylabel('Response Time (ms)')
ax3.set_title('Response Time Range (Min/Avg/Max)')
ax3.set_xticks(x)
ax3.set_xticklabels(batch_sizes)
ax3.legend()
ax3.grid(axis='y', alpha=0.3)

# Plot 4: Improvement Percentage
ax4 = axes[1, 1]
improvement_latency = ((subprocess_avg - rpy2_avg) / subprocess_avg) * 100
improvement_throughput = ((rpy2_tp - subprocess_tp) / subprocess_tp) * 100

x_imp = np.arange(len(batch_sizes))
bars1 = ax4.bar(x_imp - width/2, improvement_latency, width, label='Latency Reduction %', color='#3498DB')
bars2 = ax4.bar(x_imp + width/2, improvement_throughput, width, label='Throughput Increase %', color='#9B59B6')

ax4.set_xlabel('Batch Size (rows)')
ax4.set_ylabel('Improvement (%)')
ax4.set_title('rpy2 Performance Improvement over Subprocess')
ax4.set_xticks(x_imp)
ax4.set_xticklabels(batch_sizes)
ax4.legend()
ax4.grid(axis='y', alpha=0.3)
ax4.axhline(y=100, color='gray', linestyle='--', alpha=0.5)

for bar in bars1:
    ax4.annotate(f'{bar.get_height():.0f}%',
                xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                xytext=(0, 3), textcoords='offset points',
                ha='center', va='bottom', fontsize=9)
for bar in bars2:
    ax4.annotate(f'{bar.get_height():.0f}%',
                xy=(bar.get_x() + bar.get_width()/2, bar.get_height()),
                xytext=(0, 3), textcoords='offset points',
                ha='center', va='bottom', fontsize=9)

plt.tight_layout()
plt.savefig('benchmark_comparison.png', dpi=150, bbox_inches='tight')
plt.show()

print("\nChart saved to: benchmark_comparison.png")

# Print summary table
print("\n" + "="*70)
print("SUMMARY: rpy2 vs Subprocess Performance")
print("="*70)
print(f"\n{'Batch Size':<12} {'Latency Reduction':<20} {'Throughput Increase':<20}")
print("-"*52)
for i, batch in enumerate(batch_sizes):
    print(f"{batch:<12} {improvement_latency[i]:.1f}%{'':<14} {improvement_throughput[i]:.1f}%")
print("-"*52)
print(f"{'Average':<12} {np.mean(improvement_latency):.1f}%{'':<14} {np.mean(improvement_throughput):.1f}%")
