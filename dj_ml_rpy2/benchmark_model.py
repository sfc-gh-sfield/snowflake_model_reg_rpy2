"""
Benchmark utility for testing Snowflake Model Registry model inference performance.

This module provides functions to run repeated inference calls and collect
timing statistics to evaluate model performance.

Results can be saved to Snowflake tables for cross-notebook comparison.
"""

import time
import numpy as np
import pandas as pd
from datetime import datetime
from typing import Optional


def generate_test_data(n_rows: int, seed: Optional[int] = 42) -> pd.DataFrame:
    """
    Generate synthetic test data for ARIMAX model.
    
    Args:
        n_rows: Number of rows to generate
        seed: Random seed for reproducibility (None for random)
    
    Returns:
        DataFrame with exog_var1 and exog_var2 columns
    """
    if seed is not None:
        np.random.seed(seed)
    
    return pd.DataFrame({
        'exog_var1': np.random.normal(5, 1, n_rows),
        'exog_var2': np.random.normal(10, 2, n_rows)
    })


def run_benchmark(
    session,
    model_version,
    service_name: str,
    total_rows: int = 1000,
    rows_per_request: int = 10,
    seed: Optional[int] = 42,
    verbose: bool = True
) -> dict:
    """
    Run benchmark test on model service with configurable batch sizes.
    
    Args:
        session: Snowpark session
        model_version: Model version object from registry
        service_name: Name of the deployed service
        total_rows: Total number of rows to test
        rows_per_request: Number of rows to send in each request
        seed: Random seed for test data generation
        verbose: Print progress during benchmark
    
    Returns:
        Dictionary with timing statistics and results
    """
    # Generate all test data upfront
    all_data = generate_test_data(total_rows, seed)
    
    # Calculate number of iterations
    num_full_batches = total_rows // rows_per_request
    remaining_rows = total_rows % rows_per_request
    total_iterations = num_full_batches + (1 if remaining_rows > 0 else 0)
    
    if verbose:
        print(f"=== Benchmark Configuration ===")
        print(f"Total rows: {total_rows}")
        print(f"Rows per request: {rows_per_request}")
        print(f"Number of iterations: {total_iterations}")
        print(f"  - Full batches: {num_full_batches}")
        if remaining_rows > 0:
            print(f"  - Final batch: {remaining_rows} rows")
        print()
    
    # Collect timing data
    timings = []
    rows_per_iteration = []
    errors = []
    
    if verbose:
        print("=== Running Benchmark ===")
    
    start_idx = 0
    for i in range(total_iterations):
        # Determine batch size for this iteration
        if i < num_full_batches:
            batch_size = rows_per_request
        else:
            batch_size = remaining_rows
        
        end_idx = start_idx + batch_size
        batch_data = all_data.iloc[start_idx:end_idx].reset_index(drop=True)
        
        # Create Snowpark DataFrame
        test_df = session.create_dataframe(batch_data)
        
        # Time the inference call
        start_time = time.perf_counter()
        try:
            result = model_version.run(
                test_df,
                function_name="predict",
                service_name=service_name
            )
            # Force execution by collecting results
            _ = result.collect()
            
            end_time = time.perf_counter()
            elapsed_ms = (end_time - start_time) * 1000
            
            timings.append(elapsed_ms)
            rows_per_iteration.append(batch_size)
            
            if verbose:
                print(f"  Iteration {i+1}/{total_iterations}: {batch_size} rows, {elapsed_ms:.2f}ms")
                
        except Exception as e:
            end_time = time.perf_counter()
            elapsed_ms = (end_time - start_time) * 1000
            errors.append({
                'iteration': i + 1,
                'error': str(e),
                'elapsed_ms': elapsed_ms
            })
            if verbose:
                print(f"  Iteration {i+1}/{total_iterations}: ERROR - {str(e)[:50]}...")
        
        start_idx = end_idx
    
    # Calculate statistics
    if timings:
        timings_array = np.array(timings)
        stats = {
            'total_rows': total_rows,
            'rows_per_request': rows_per_request,
            'total_iterations': total_iterations,
            'successful_iterations': len(timings),
            'failed_iterations': len(errors),
            'total_time_ms': sum(timings),
            'avg_ms': np.mean(timings_array),
            'min_ms': np.min(timings_array),
            'max_ms': np.max(timings_array),
            'std_ms': np.std(timings_array),
            'p50_ms': np.percentile(timings_array, 50),
            'p90_ms': np.percentile(timings_array, 90),
            'p95_ms': np.percentile(timings_array, 95),
            'p99_ms': np.percentile(timings_array, 99),
            'throughput_rows_per_sec': (sum(rows_per_iteration) / sum(timings)) * 1000,
            'timings': timings,
            'rows_per_iteration': rows_per_iteration,
            'errors': errors
        }
    else:
        stats = {
            'total_rows': total_rows,
            'rows_per_request': rows_per_request,
            'total_iterations': total_iterations,
            'successful_iterations': 0,
            'failed_iterations': len(errors),
            'errors': errors
        }
    
    if verbose:
        print()
        print_benchmark_results(stats)
    
    return stats


def print_benchmark_results(stats: dict):
    """Print formatted benchmark results."""
    print("=== Benchmark Results ===")
    print(f"Total rows processed: {stats.get('total_rows', 0)}")
    print(f"Rows per request: {stats.get('rows_per_request', 0)}")
    print(f"Successful iterations: {stats.get('successful_iterations', 0)}/{stats.get('total_iterations', 0)}")
    
    if stats.get('successful_iterations', 0) > 0:
        print()
        print("Timing Statistics (milliseconds):")
        print(f"  Total time:    {stats['total_time_ms']:.2f}ms")
        print(f"  Average:       {stats['avg_ms']:.2f}ms")
        print(f"  Min:           {stats['min_ms']:.2f}ms")
        print(f"  Max:           {stats['max_ms']:.2f}ms")
        print(f"  Std Dev:       {stats['std_ms']:.2f}ms")
        print()
        print("Percentiles:")
        print(f"  P50 (median):  {stats['p50_ms']:.2f}ms")
        print(f"  P90:           {stats['p90_ms']:.2f}ms")
        print(f"  P95:           {stats['p95_ms']:.2f}ms")
        print(f"  P99:           {stats['p99_ms']:.2f}ms")
        print()
        print(f"Throughput: {stats['throughput_rows_per_sec']:.2f} rows/second")
    
    if stats.get('failed_iterations', 0) > 0:
        print()
        print(f"Errors ({stats['failed_iterations']} failures):")
        for err in stats.get('errors', [])[:5]:  # Show first 5 errors
            print(f"  Iteration {err['iteration']}: {err['error'][:80]}...")


def compare_benchmarks(stats_list: list, labels: list):
    """
    Compare multiple benchmark results side by side.
    
    Args:
        stats_list: List of stats dictionaries from run_benchmark
        labels: List of labels for each benchmark
    """
    print("=== Benchmark Comparison ===")
    print()
    
    # Header
    header = f"{'Metric':<20}"
    for label in labels:
        header += f"{label:>15}"
    print(header)
    print("-" * len(header))
    
    metrics = [
        ('Rows/request', 'rows_per_request'),
        ('Iterations', 'successful_iterations'),
        ('Total time (ms)', 'total_time_ms'),
        ('Avg (ms)', 'avg_ms'),
        ('Min (ms)', 'min_ms'),
        ('Max (ms)', 'max_ms'),
        ('P50 (ms)', 'p50_ms'),
        ('P90 (ms)', 'p90_ms'),
        ('P95 (ms)', 'p95_ms'),
        ('P99 (ms)', 'p99_ms'),
        ('Throughput (r/s)', 'throughput_rows_per_sec'),
    ]
    
    for metric_label, metric_key in metrics:
        row = f"{metric_label:<20}"
        for stats in stats_list:
            value = stats.get(metric_key, 'N/A')
            if isinstance(value, float):
                row += f"{value:>15.2f}"
            else:
                row += f"{value:>15}"
        print(row)


def save_benchmark_to_snowflake(
    session,
    stats: dict,
    service_name: str,
    model_type: str,
    table_name: str = "BENCHMARK_RESULTS",
    database: Optional[str] = None,
    schema: Optional[str] = None,
    run_id: Optional[str] = None
) -> str:
    """
    Save benchmark results to a Snowflake table for comparison.
    
    Args:
        session: Snowpark session
        stats: Statistics dictionary from run_benchmark
        service_name: Name of the service being tested
        model_type: Type of model (e.g., 'subprocess', 'rpy2')
        table_name: Name of the results table
        database: Database name (uses session default if None)
        schema: Schema name (uses session default if None)
        run_id: Optional run identifier (auto-generated if None)
    
    Returns:
        The run_id used for this benchmark
    """
    if run_id is None:
        run_id = datetime.now().strftime("%Y%m%d_%H%M%S")
    
    # Build fully qualified table name
    if database and schema:
        full_table_name = f"{database}.{schema}.{table_name}"
    else:
        full_table_name = table_name
    
    # Create table if not exists
    create_sql = f"""
    CREATE TABLE IF NOT EXISTS {full_table_name} (
        run_id VARCHAR,
        run_timestamp TIMESTAMP_NTZ,
        service_name VARCHAR,
        model_type VARCHAR,
        total_rows INTEGER,
        rows_per_request INTEGER,
        total_iterations INTEGER,
        successful_iterations INTEGER,
        failed_iterations INTEGER,
        total_time_ms FLOAT,
        avg_ms FLOAT,
        min_ms FLOAT,
        max_ms FLOAT,
        std_ms FLOAT,
        p50_ms FLOAT,
        p90_ms FLOAT,
        p95_ms FLOAT,
        p99_ms FLOAT,
        throughput_rows_per_sec FLOAT
    )
    """
    session.sql(create_sql).collect()
    
    # Insert results
    insert_sql = f"""
    INSERT INTO {full_table_name} (
        run_id, run_timestamp, service_name, model_type,
        total_rows, rows_per_request, total_iterations,
        successful_iterations, failed_iterations,
        total_time_ms, avg_ms, min_ms, max_ms, std_ms,
        p50_ms, p90_ms, p95_ms, p99_ms, throughput_rows_per_sec
    ) VALUES (
        '{run_id}',
        CURRENT_TIMESTAMP(),
        '{service_name}',
        '{model_type}',
        {stats.get('total_rows', 0)},
        {stats.get('rows_per_request', 0)},
        {stats.get('total_iterations', 0)},
        {stats.get('successful_iterations', 0)},
        {stats.get('failed_iterations', 0)},
        {stats.get('total_time_ms', 0)},
        {stats.get('avg_ms', 0)},
        {stats.get('min_ms', 0)},
        {stats.get('max_ms', 0)},
        {stats.get('std_ms', 0)},
        {stats.get('p50_ms', 0)},
        {stats.get('p90_ms', 0)},
        {stats.get('p95_ms', 0)},
        {stats.get('p99_ms', 0)},
        {stats.get('throughput_rows_per_sec', 0)}
    )
    """
    session.sql(insert_sql).collect()
    
    print(f"Results saved to {full_table_name} with run_id: {run_id}")
    return run_id


def run_and_save_benchmark(
    session,
    model_version,
    service_name: str,
    model_type: str,
    total_rows: int = 100,
    rows_per_request: int = 10,
    table_name: str = "BENCHMARK_RESULTS",
    database: Optional[str] = None,
    schema: Optional[str] = None,
    run_id: Optional[str] = None,
    seed: Optional[int] = 42,
    verbose: bool = True
) -> dict:
    """
    Run benchmark and save results to Snowflake in one call.
    
    Args:
        session: Snowpark session
        model_version: Model version object from registry
        service_name: Name of the deployed service
        model_type: Type of model (e.g., 'subprocess', 'rpy2')
        total_rows: Total number of rows to test
        rows_per_request: Number of rows per request
        table_name: Name of the results table
        database: Database name
        schema: Schema name
        run_id: Optional run identifier
        seed: Random seed
        verbose: Print progress
    
    Returns:
        Statistics dictionary
    """
    stats = run_benchmark(
        session=session,
        model_version=model_version,
        service_name=service_name,
        total_rows=total_rows,
        rows_per_request=rows_per_request,
        seed=seed,
        verbose=verbose
    )
    
    save_benchmark_to_snowflake(
        session=session,
        stats=stats,
        service_name=service_name,
        model_type=model_type,
        table_name=table_name,
        database=database,
        schema=schema,
        run_id=run_id
    )
    
    return stats


def load_benchmark_results(
    session,
    table_name: str = "BENCHMARK_RESULTS",
    database: Optional[str] = None,
    schema: Optional[str] = None,
    run_id: Optional[str] = None,
    model_type: Optional[str] = None
) -> pd.DataFrame:
    """
    Load benchmark results from Snowflake table.
    
    Args:
        session: Snowpark session
        table_name: Name of the results table
        database: Database name
        schema: Schema name
        run_id: Filter by specific run_id (optional)
        model_type: Filter by model type (optional)
    
    Returns:
        DataFrame with benchmark results
    """
    if database and schema:
        full_table_name = f"{database}.{schema}.{table_name}"
    else:
        full_table_name = table_name
    
    query = f"SELECT * FROM {full_table_name}"
    
    conditions = []
    if run_id:
        conditions.append(f"run_id = '{run_id}'")
    if model_type:
        conditions.append(f"model_type = '{model_type}'")
    
    if conditions:
        query += " WHERE " + " AND ".join(conditions)
    
    query += " ORDER BY run_timestamp DESC, rows_per_request"
    
    return session.sql(query).to_pandas()


def compare_from_table(
    session,
    table_name: str = "BENCHMARK_RESULTS",
    database: Optional[str] = None,
    schema: Optional[str] = None,
    run_ids: Optional[list] = None
):
    """
    Compare benchmark results from Snowflake table.
    
    Args:
        session: Snowpark session
        table_name: Name of the results table
        database: Database name
        schema: Schema name
        run_ids: List of run_ids to compare (uses latest if None)
    """
    df = load_benchmark_results(session, table_name, database, schema)
    
    if df.empty:
        print("No benchmark results found.")
        return
    
    if run_ids:
        df = df[df['RUN_ID'].isin(run_ids)]
    
    # Pivot for comparison
    print("\n=== Benchmark Comparison from Snowflake ===\n")
    
    # Group by model_type and rows_per_request for comparison
    comparison = df.pivot_table(
        index='ROWS_PER_REQUEST',
        columns='MODEL_TYPE',
        values=['AVG_MS', 'P50_MS', 'P95_MS', 'THROUGHPUT_ROWS_PER_SEC'],
        aggfunc='mean'
    )
    
    print(comparison.round(2).to_string())
    
    return df


# Example usage (to be run in notebook):
"""
from benchmark_model import run_and_save_benchmark, compare_from_table

# === In SUBPROCESS notebook ===
for batch_size in [10, 25, 50]:
    run_and_save_benchmark(
        session=session,
        model_version=model_version,
        service_name="arimax_deployment",
        model_type="subprocess",
        total_rows=100,
        rows_per_request=batch_size,
        table_name="BENCHMARK_RESULTS",
        run_id="test_run_001"
    )

# === In RPY2 notebook ===
for batch_size in [10, 25, 50]:
    run_and_save_benchmark(
        session=session,
        model_version=model_version,
        service_name="arimax_rpy2_deployment",
        model_type="rpy2",
        total_rows=100,
        rows_per_request=batch_size,
        table_name="BENCHMARK_RESULTS",
        run_id="test_run_001"
    )

# === Compare results (in either notebook) ===
compare_from_table(session, table_name="BENCHMARK_RESULTS")
"""
