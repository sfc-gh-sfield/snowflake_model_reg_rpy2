"""
rpy2-based Python wrapper for R ARIMAX model.

This implementation uses rpy2 for direct Python-R interoperability,
avoiding the overhead of CSV file I/O and subprocess execution.

Updated for rpy2 3.6.x API (removed deprecated pandas2ri.activate()).

IMPORTANT: All rpy2 imports are done inside methods to avoid pickle issues.
Module-level rpy2 imports create objects with weak references that cannot be serialized.
"""

import pandas as pd
import numpy as np
import uuid
from snowflake.ml.model import custom_model


def _get_rpy2_components():
    """
    Lazy import of rpy2 components to avoid pickle issues.
    
    Returns tuple of (ro, r, FloatVector, localconverter, RRuntimeError, combined_converter)
    """
    import rpy2.robjects as ro
    from rpy2.robjects import pandas2ri, r
    from rpy2.robjects.vectors import FloatVector
    from rpy2.robjects.conversion import localconverter
    from rpy2.rinterface_lib.embedded import RRuntimeError
    from rpy2.robjects import numpy2ri
    
    # Create combined converter that handles both pandas and numpy
    combined_converter = ro.default_converter + pandas2ri.converter + numpy2ri.converter
    
    return ro, r, FloatVector, localconverter, RRuntimeError, combined_converter


class ARIMAXModelWrapperRpy2(custom_model.CustomModel):
    """
    Python wrapper for R ARIMAX model using rpy2 for direct R execution.
    
    This wrapper provides:
    - Direct in-memory data transfer between Python and R
    - No file I/O overhead (no CSV serialization)
    - No subprocess spawning
    - Better error handling with Python-native exceptions
    
    Performance benefits over subprocess approach:
    - ~5-20x faster per-prediction (eliminates I/O overhead)
    - Lower memory footprint per prediction
    - Type fidelity preserved (no CSV conversion loss)
    
    Compatible with rpy2 3.6.x (uses R evaluation for generic functions).
    
    Note: Uses lazy initialization to avoid pickle issues with R objects.
    """
    
    def __init__(self, context: custom_model.ModelContext):
        """
        Initialize the ARIMAX model wrapper with rpy2.
        
        Args:
            context: ModelContext containing 'model_rds' artifact path
        """
        super().__init__(context)
        # Use lazy initialization - don't load R objects here
        # R objects contain weak references that can't be pickled
        self._initialized = False
        # Unique name for this model instance in R's global environment
        self._r_model_name = f"arimax_model_{uuid.uuid4().hex[:8]}"
    
    def _ensure_initialized(self):
        """Lazy initialization of R resources - called on first predict."""
        if self._initialized:
            return
        
        # Import rpy2 components lazily
        ro, _, _, localconverter, _, combined_converter = _get_rpy2_components()
        
        # Use localconverter to ensure conversion context is available
        with localconverter(combined_converter):
            # Load forecast library in R
            ro.r('library(forecast)')
            
            # Load the model DIRECTLY into R's global environment
            # Keep it there permanently - don't try to pass R objects through Python
            model_path = self.context['model_rds']
            ro.r(f'{self._r_model_name} <- readRDS("{model_path}")')
        
        self._initialized = True
        
    @custom_model.inference_api
    def predict(self, X: pd.DataFrame) -> pd.DataFrame:
        """
        Make predictions using the R ARIMAX model via rpy2.
        
        Data conversion happens in-memory:
        - Input: pandas DataFrame → numpy array → R matrix (via FloatVector)
        - Output: R forecast object → numpy arrays → pandas DataFrame
        
        Args:
            X: DataFrame with columns 'exog_var1' and 'exog_var2'
        
        Returns:
            DataFrame with columns: forecast, lower_80, upper_80, lower_95, upper_95
        """
        # Ensure R is initialized (lazy loading to avoid pickle issues)
        self._ensure_initialized()
        
        required_cols = ['exog_var1', 'exog_var2']
        if not all(col in X.columns for col in required_cols):
            raise ValueError(f"Input DataFrame must contain columns: {required_cols}")
        
        # Import rpy2 components lazily
        ro, r, FloatVector, localconverter, RRuntimeError, combined_converter = _get_rpy2_components()
        
        # Generate unique variable names for temporary data (thread-safe)
        uid = uuid.uuid4().hex[:8]
        var_xreg = f"xreg_{uid}"
        var_pred = f"pred_{uid}"
        
        # Variable names for extracted results
        var_mean = f"mean_{uid}"
        var_lower = f"lower_{uid}"
        var_upper = f"upper_{uid}"
        
        try:
            # Use localconverter to ensure conversion context is available in threads
            with localconverter(combined_converter):
                # Extract exogenous variables
                exog_data = X[required_cols].values.astype(np.float64)
                n_ahead = len(X)
                
                # Create R matrix for xreg (using FloatVector for direct conversion)
                xreg_new = r['matrix'](
                    FloatVector(exog_data.flatten()),
                    nrow=n_ahead,
                    ncol=2,
                    byrow=True
                )
                
                # Pass xreg to R environment
                ro.globalenv[var_xreg] = xreg_new
                
                # Run forecast and extract results all in R
                # This avoids issues with R-to-Python object conversion
                ro.r(f'''
                    colnames({var_xreg}) <- c("exog_var1", "exog_var2")
                    {var_pred} <- forecast({self._r_model_name}, xreg={var_xreg}, h={n_ahead})
                    {var_mean} <- as.numeric({var_pred}$mean)
                    {var_lower} <- as.matrix({var_pred}$lower)
                    {var_upper} <- as.matrix({var_pred}$upper)
                ''')
                
                # Now retrieve the extracted arrays (these convert cleanly to numpy)
                forecast_mean = np.array(ro.globalenv[var_mean]).flatten()
                lower_intervals = np.array(ro.globalenv[var_lower])
                upper_intervals = np.array(ro.globalenv[var_upper])
                
                # Handle single-row case: ensure 2D arrays
                if lower_intervals.ndim == 1:
                    lower_intervals = lower_intervals.reshape(1, -1)
                if upper_intervals.ndim == 1:
                    upper_intervals = upper_intervals.reshape(1, -1)
                
                # Clean up temporary variables only (keep model in R)
                ro.r(f'rm({var_xreg}, {var_pred}, {var_mean}, {var_lower}, {var_upper})')
            
            # Build output DataFrame
            output = pd.DataFrame({
                'forecast': forecast_mean,
                'lower_80': lower_intervals[:, 0],
                'upper_80': upper_intervals[:, 0],
                'lower_95': lower_intervals[:, 1],
                'upper_95': upper_intervals[:, 1]
            })
            
            return output
            
        except RRuntimeError as e:
            # Clean up on error
            try:
                ro.r(f'rm({var_xreg}, {var_pred}, {var_mean}, {var_lower}, {var_upper})')
            except Exception:
                pass
            raise RuntimeError(f"R execution error: {str(e)}")
        except Exception as e:
            # Clean up on error
            try:
                ro.r(f'rm({var_xreg}, {var_pred}, {var_mean}, {var_lower}, {var_upper})')
            except Exception:
                pass
            raise RuntimeError(f"Prediction failed: {str(e)}")


class ARIMAXModelWrapperRpy2Lazy(custom_model.CustomModel):
    """
    Alternative implementation with lazy R initialization.
    
    This version delays R package imports and model loading until
    the first prediction call, which can be useful if:
    - The model might not always be used
    - You want to serialize the wrapper before R is available
    
    Compatible with rpy2 3.6.x.
    """
    
    def __init__(self, context: custom_model.ModelContext):
        """
        Initialize the wrapper without loading R resources.
        
        Args:
            context: ModelContext containing 'model_rds' artifact path
        """
        super().__init__(context)
        self._initialized = False
        # Unique name for this model instance in R's global environment
        self._r_model_name = f"arimax_model_{uuid.uuid4().hex[:8]}"
        
    def _ensure_initialized(self):
        """Lazy initialization of R resources."""
        if self._initialized:
            return
        
        # Import rpy2 components lazily
        ro, _, _, localconverter, _, combined_converter = _get_rpy2_components()
        
        # Use localconverter to ensure conversion context is available
        with localconverter(combined_converter):
            # Load forecast library in R
            ro.r('library(forecast)')
            
            # Load the model DIRECTLY into R's global environment
            model_path = self.context['model_rds']
            ro.r(f'{self._r_model_name} <- readRDS("{model_path}")')
        
        self._initialized = True
    
    @custom_model.inference_api
    def predict(self, X: pd.DataFrame) -> pd.DataFrame:
        """
        Make predictions using the R ARIMAX model via rpy2.
        
        Args:
            X: DataFrame with columns 'exog_var1' and 'exog_var2'
        
        Returns:
            DataFrame with forecast and confidence intervals
        """
        # Ensure R is initialized
        self._ensure_initialized()
        
        required_cols = ['exog_var1', 'exog_var2']
        if not all(col in X.columns for col in required_cols):
            raise ValueError(f"Input DataFrame must contain columns: {required_cols}")
        
        # Import rpy2 components lazily
        ro, r, FloatVector, localconverter, RRuntimeError, combined_converter = _get_rpy2_components()
        
        # Generate unique variable names for temporary data (thread-safe)
        uid = uuid.uuid4().hex[:8]
        var_xreg = f"xreg_{uid}"
        var_pred = f"pred_{uid}"
        var_mean = f"mean_{uid}"
        var_lower = f"lower_{uid}"
        var_upper = f"upper_{uid}"
        
        try:
            # Use localconverter to ensure conversion context is available in threads
            with localconverter(combined_converter):
                # Extract exogenous variables
                exog_data = X[required_cols].values.astype(np.float64)
                n_ahead = len(X)
                
                # Create R matrix for xreg
                xreg_new = r['matrix'](
                    FloatVector(exog_data.flatten()),
                    nrow=n_ahead,
                    ncol=2,
                    byrow=True
                )
                
                # Pass xreg to R environment
                ro.globalenv[var_xreg] = xreg_new
                
                # Run forecast and extract results all in R
                ro.r(f'''
                    colnames({var_xreg}) <- c("exog_var1", "exog_var2")
                    {var_pred} <- forecast({self._r_model_name}, xreg={var_xreg}, h={n_ahead})
                    {var_mean} <- as.numeric({var_pred}$mean)
                    {var_lower} <- as.matrix({var_pred}$lower)
                    {var_upper} <- as.matrix({var_pred}$upper)
                ''')
                
                # Now retrieve the extracted arrays (these convert cleanly to numpy)
                forecast_mean = np.array(ro.globalenv[var_mean]).flatten()
                lower_intervals = np.array(ro.globalenv[var_lower])
                upper_intervals = np.array(ro.globalenv[var_upper])
                
                # Handle single-row case: ensure 2D arrays
                if lower_intervals.ndim == 1:
                    lower_intervals = lower_intervals.reshape(1, -1)
                if upper_intervals.ndim == 1:
                    upper_intervals = upper_intervals.reshape(1, -1)
                
                # Clean up temporary variables only (keep model in R)
                ro.r(f'rm({var_xreg}, {var_pred}, {var_mean}, {var_lower}, {var_upper})')
            
            # Build output DataFrame
            output = pd.DataFrame({
                'forecast': forecast_mean,
                'lower_80': lower_intervals[:, 0],
                'upper_80': upper_intervals[:, 0],
                'lower_95': lower_intervals[:, 1],
                'upper_95': upper_intervals[:, 1]
            })
            
            return output
            
        except RRuntimeError as e:
            # Clean up on error
            try:
                ro.r(f'rm({var_xreg}, {var_pred}, {var_mean}, {var_lower}, {var_upper})')
            except Exception:
                pass
            raise RuntimeError(f"R execution error: {str(e)}")
        except Exception as e:
            # Clean up on error
            try:
                ro.r(f'rm({var_xreg}, {var_pred}, {var_mean}, {var_lower}, {var_upper})')
            except Exception:
                pass
            raise RuntimeError(f"Prediction failed: {str(e)}")


def convert_pandas_to_r(df: pd.DataFrame):
    """
    Convert a pandas DataFrame to an R data.frame using rpy2 3.6.x API.
    
    Uses localconverter context manager (replaces deprecated pandas2ri.activate()).
    
    Args:
        df: pandas DataFrame to convert
        
    Returns:
        R data.frame object
    """
    ro, _, _, localconverter, _, combined_converter = _get_rpy2_components()
    with localconverter(combined_converter):
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
    ro, _, _, localconverter, _, combined_converter = _get_rpy2_components()
    with localconverter(combined_converter):
        return ro.conversion.rpy2py(r_obj)
