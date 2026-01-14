import subprocess
import tempfile
import os
import pandas as pd
from typing import Optional
import pickle
from snowflake.ml.model import custom_model


class ARIMAXModelWrapper(custom_model.CustomModel):
    """
    Python wrapper for R ARIMAX model to enable logging to Snowflake Model Registry.
    
    This wrapper handles:
    - Data serialization between Python and R (via CSV)
    - Subprocess execution of R prediction script
    - Error handling and validation
    """
    
    def __init__(self, context: custom_model.ModelContext):
        """
        Initialize the ARIMAX model wrapper.
        
        Args:
            context: ModelContext containing 'model_rds' and 'predict_script' artifacts
        """
        super().__init__(context)
        
        # Load model bytes from context
        with open(self.context['model_rds'], 'rb') as f:
            self.model_bytes = f.read()
        
        # Load prediction script from context
        with open(self.context['predict_script'], 'r') as f:
            self.predict_script = f.read()
    
    def _write_temp_files(self) -> tuple:
        """Write model and script to temporary files for execution."""
        temp_dir = tempfile.mkdtemp()
        
        model_path = os.path.join(temp_dir, "model.rds")
        with open(model_path, 'wb') as f:
            f.write(self.model_bytes)
        
        script_path = os.path.join(temp_dir, "predict.R")
        with open(script_path, 'w') as f:
            f.write(self.predict_script)
        
        return temp_dir, model_path, script_path
    
    @custom_model.inference_api
    def predict(self, X: pd.DataFrame) -> pd.DataFrame:
        """
        Make predictions using the R ARIMAX model.
        
        Args:
            X: DataFrame with columns 'exog_var1' and 'exog_var2'
        
        Returns:
            DataFrame with forecast and confidence intervals
        """
        required_cols = ['exog_var1', 'exog_var2']
        if not all(col in X.columns for col in required_cols):
            raise ValueError(f"Input DataFrame must contain columns: {required_cols}")
        
        temp_dir, model_path, script_path = self._write_temp_files()
        
        try:
            input_csv = os.path.join(temp_dir, "input.csv")
            output_csv = os.path.join(temp_dir, "output.csv")
            
            X[required_cols].to_csv(input_csv, index=False)
            
            cmd = [
                "Rscript",
                script_path,
                model_path,
                input_csv,
                output_csv
            ]
            
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True,
                timeout=300
            )
            
            if not os.path.exists(output_csv):
                raise RuntimeError(f"R script did not produce output file. stdout: {result.stdout}, stderr: {result.stderr}")
            
            predictions = pd.read_csv(output_csv)
            
            return predictions
            
        except subprocess.CalledProcessError as e:
            raise RuntimeError(
                f"R prediction script failed.\n"
                f"Return code: {e.returncode}\n"
                f"stdout: {e.stdout}\n"
                f"stderr: {e.stderr}"
            )
        except subprocess.TimeoutExpired:
            raise RuntimeError("R prediction script timed out after 300 seconds")
        finally:
            import shutil
            if os.path.exists(temp_dir):
                shutil.rmtree(temp_dir)
