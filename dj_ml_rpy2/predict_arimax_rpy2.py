"""
Standalone prediction module using rpy2.

This module provides functions for making predictions with R ARIMAX models
without the CustomModel wrapper. Useful for local testing and development.

Updated for rpy2 3.6.x API (removed deprecated pandas2ri.activate()).
"""

import pandas as pd
import numpy as np
from typing import Union
from pathlib import Path

import rpy2.robjects as ro
from rpy2.robjects import pandas2ri, r
from rpy2.robjects.vectors import FloatVector
from rpy2.robjects.conversion import localconverter
from rpy2.rinterface_lib.embedded import RRuntimeError


def load_arimax_model(model_path: Union[str, Path]):
    """
    Load an ARIMAX model from an RDS file.
    
    Args:
        model_path: Path to the .rds model file
        
    Returns:
        R model object
    """
    return r['readRDS'](str(model_path))


def predict_arimax(
    model,
    exog_var1: Union[list, np.ndarray],
    exog_var2: Union[list, np.ndarray]
) -> pd.DataFrame:
    """
    Make predictions using an ARIMAX model.
    
    Args:
        model: R ARIMAX model object (from load_arimax_model)
        exog_var1: Values for first exogenous variable
        exog_var2: Values for second exogenous variable
        
    Returns:
        DataFrame with forecast and confidence intervals
    """
    # Ensure forecast package is loaded
    ro.r('library(forecast)')
    
    # Prepare exogenous variables as R matrix
    exog_var1 = np.array(exog_var1)
    exog_var2 = np.array(exog_var2)
    n_ahead = len(exog_var1)
    
    if len(exog_var2) != n_ahead:
        raise ValueError("exog_var1 and exog_var2 must have the same length")
    
    # Stack and create R matrix (using FloatVector for direct conversion)
    exog_data = np.column_stack([exog_var1, exog_var2])
    xreg_new = r['matrix'](
        FloatVector(exog_data.flatten()),
        nrow=n_ahead,
        ncol=2,
        byrow=True
    )
    
    # Pass data to R environment and call forecast (rpy2 3.6.x compatible)
    ro.globalenv['temp.model'] = model
    ro.globalenv['temp.xreg'] = xreg_new
    ro.globalenv['temp.h'] = n_ahead
    
    ro.r('colnames(temp.xreg) <- c("exog_var1", "exog_var2")')
    ro.r('temp.predictions <- forecast(temp.model, xreg=temp.xreg, h=temp.h)')
    
    predictions = ro.globalenv['temp.predictions']
    
    # Extract components
    forecast_mean = np.array(predictions.rx2('mean'))
    lower_intervals = np.array(predictions.rx2('lower'))
    upper_intervals = np.array(predictions.rx2('upper'))
    
    # Clean up R environment
    ro.r('rm(temp.model, temp.xreg, temp.h, temp.predictions)')
    
    return pd.DataFrame({
        'forecast': forecast_mean,
        'lower_80': lower_intervals[:, 0],
        'upper_80': upper_intervals[:, 0],
        'lower_95': lower_intervals[:, 1],
        'upper_95': upper_intervals[:, 1]
    })


def predict_arimax_from_dataframe(
    model,
    df: pd.DataFrame,
    exog_cols: list = ['exog_var1', 'exog_var2']
) -> pd.DataFrame:
    """
    Make predictions from a DataFrame.
    
    Args:
        model: R ARIMAX model object
        df: DataFrame containing exogenous variables
        exog_cols: Column names for exogenous variables
        
    Returns:
        DataFrame with forecast and confidence intervals
    """
    if not all(col in df.columns for col in exog_cols):
        raise ValueError(f"DataFrame must contain columns: {exog_cols}")
    
    return predict_arimax(
        model,
        df[exog_cols[0]].values,
        df[exog_cols[1]].values
    )


def convert_pandas_to_r(df: pd.DataFrame):
    """
    Convert a pandas DataFrame to an R data.frame using rpy2 3.6.x API.
    
    Uses localconverter context manager (replaces deprecated pandas2ri.activate()).
    
    Args:
        df: pandas DataFrame to convert
        
    Returns:
        R data.frame object
    """
    with localconverter(ro.default_converter + pandas2ri.converter):
        return ro.conversion.py2rpy(df)


def convert_r_to_pandas(r_obj) -> pd.DataFrame:
    """
    Convert an R data.frame to a pandas DataFrame using rpy2 3.6.x API.
    
    Uses localconverter context manager (replaces deprecated pandas2ri.activate()).
    
    Args:
        r_obj: R data.frame object
        
    Returns:
        pandas DataFrame
    """
    with localconverter(ro.default_converter + pandas2ri.converter):
        return ro.conversion.rpy2py(r_obj)


# Example usage / test
if __name__ == "__main__":
    import os
    
    # Check if model exists
    model_path = os.path.join(os.path.dirname(__file__), '..', 'dj_ml', 'arimax_model_artifact.rds')
    
    if os.path.exists(model_path):
        print("Loading ARIMAX model...")
        model = load_arimax_model(model_path)
        
        print("Generating test data...")
        np.random.seed(42)
        test_data = pd.DataFrame({
            'exog_var1': np.random.normal(5, 1, 10),
            'exog_var2': np.random.normal(10, 2, 10)
        })
        
        print("\nInput data:")
        print(test_data)
        
        print("\nMaking predictions...")
        predictions = predict_arimax_from_dataframe(model, test_data)
        
        print("\nPredictions:")
        print(predictions)
    else:
        print(f"Model not found at: {model_path}")
        print("Run train_arimax.R first to create the model.")
