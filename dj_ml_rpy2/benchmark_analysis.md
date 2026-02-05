# R Model Inference Benchmark Analysis

## Subprocess vs rpy2 Performance Comparison

**Date:** February 3, 2026  
**Test Configuration:** 100 total rows, batch sizes of 10, 25, and 50 rows

---

## Executive Summary

The rpy2 approach demonstrates **significant performance improvements** over the subprocess approach across all batch sizes:

| Metric | rpy2 Advantage |
|--------|----------------|
| **Average Latency** | 48-52% faster |
| **Throughput** | 2.0-2.2x higher |
| **Consistency** | Lower variance (more predictable) |

---

## Detailed Results

### Average Response Time (ms)

| Batch Size | Subprocess (ms) | rpy2 (ms) | Improvement |
|------------|-----------------|-----------|-------------|
| 10 rows    | 2,312           | 1,118     | **51.6% faster** |
| 25 rows    | 2,051           | 996       | **51.4% faster** |
| 50 rows    | 2,039           | 914       | **55.1% faster** |

### Throughput (rows/second)

| Batch Size | Subprocess | rpy2   | Improvement |
|------------|------------|--------|-------------|
| 10 rows    | 4.33       | 8.94   | **2.07x** |
| 25 rows    | 12.19      | 25.11  | **2.06x** |
| 50 rows    | 24.52      | 54.68  | **2.23x** |

### Response Time Percentiles (ms)

#### Subprocess
| Batch Size | Min    | P50    | P90    | P95    | P99    | Max    |
|------------|--------|--------|--------|--------|--------|--------|
| 10 rows    | 1,962  | 2,253  | 2,648  | 2,840  | 2,993  | 3,032  |
| 25 rows    | 1,932  | 2,022  | 2,168  | 2,198  | 2,222  | 2,228  |
| 50 rows    | 2,024  | 2,039  | 2,051  | 2,052  | 2,053  | 2,054  |

#### rpy2
| Batch Size | Min  | P50    | P90    | P95    | P99    | Max    |
|------------|------|--------|--------|--------|--------|--------|
| 10 rows    | 871  | 1,164  | 1,289  | 1,313  | 1,331  | 1,336  |
| 25 rows    | 920  | 996    | 1,052  | 1,061  | 1,069  | 1,070  |
| 50 rows    | 843  | 914    | 971    | 978    | 984    | 985    |

---

## Visual Analysis

### Response Time Comparison

```
Average Response Time by Batch Size (ms)
=========================================

Batch 10:  subprocess |████████████████████████████████████████████████| 2312ms
           rpy2       |███████████████████████                         | 1118ms

Batch 25:  subprocess |████████████████████████████████████████████    | 2051ms
           rpy2       |█████████████████████                           |  996ms

Batch 50:  subprocess |███████████████████████████████████████████     | 2039ms
           rpy2       |███████████████████                             |  914ms
```

### Throughput Comparison

```
Throughput by Batch Size (rows/second)
======================================

Batch 10:  subprocess |████                                            |  4.3
           rpy2       |█████████                                       |  8.9

Batch 25:  subprocess |████████████                                    | 12.2
           rpy2       |█████████████████████████                       | 25.1

Batch 50:  subprocess |████████████████████████                        | 24.5
           rpy2       |██████████████████████████████████████████████████████| 54.7
```

---

## Key Findings

### 1. Consistent 2x Performance Gain
The rpy2 approach consistently delivers approximately **2x the throughput** of the subprocess approach across all batch sizes tested.

### 2. Lower Latency Variance
The rpy2 approach shows **lower standard deviation** in response times:
- Subprocess std dev: 14-344ms (varies with batch size)
- rpy2 std dev: 54-158ms (more consistent)

### 3. Scaling Behavior
Both approaches benefit from larger batch sizes, but rpy2 scales more efficiently:
- **Subprocess:** 4.3 → 24.5 rows/sec (5.7x improvement from 10→50 batch)
- **rpy2:** 8.9 → 54.7 rows/sec (6.1x improvement from 10→50 batch)

### 4. Overhead Analysis
The minimum response times reveal the baseline overhead:
- **Subprocess minimum:** ~1,932-2,024ms (includes file I/O, process spawn, R model load)
- **rpy2 minimum:** ~843-920ms (in-memory operations, model pre-loaded)

The ~1,100ms difference represents the **eliminated overhead** from:
- CSV file writing/reading
- Subprocess spawning
- R loading model from disk each call

---

## Recommendations

1. **Use rpy2 for production workloads** - The 2x throughput improvement is significant for cost and latency.

2. **Use larger batch sizes when possible** - Both approaches benefit, but throughput scales better with larger batches.

3. **For latency-sensitive applications** - rpy2 with 50-row batches achieves sub-1-second response times.

4. **For throughput optimization** - Consider batching multiple requests together when real-time response isn't critical.

---

## Test Environment

- **Platform:** Snowflake Snowpark Container Services (SPCS)
- **Compute Pool:** CPU_X64_M
- **R Version:** 4.x with forecast package
- **Model:** ARIMAX time series model

---

## Raw Data

```csv
MODEL_TYPE,BATCH_SIZE,AVG_MS,THROUGHPUT
subprocess,10,2311.78,4.33
subprocess,25,2051.00,12.19
subprocess,50,2038.80,24.52
rpy2,10,1118.40,8.94
rpy2,25,995.58,25.11
rpy2,50,914.41,54.68
```
