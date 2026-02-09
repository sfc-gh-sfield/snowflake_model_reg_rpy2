"""
Snowflake-R Bridge for Remote Dev Environment

This module provides easy-to-use functions for connecting R to Snowflake
via Python, using rpy2 for the R-Python bridge and Arrow for high-performance
data transfer.

Usage:
    from snowflake_r_bridge import SnowflakeRBridge
    
    bridge = SnowflakeRBridge(
        account="ak32940",
        user="SIMON", 
        private_key_path="/root/.snowflake/keys/simon_rsa_key.p8",
        database="SIMON",
        warehouse="SIMON_XS"
    )
    
    # Execute query and get result in R
    bridge.query_to_r("SELECT * FROM my_table LIMIT 100", "my_data")
    
    # Run R code on the data
    bridge.run_r('''
        library(dplyr)
        result <- my_data %>% group_by(col) %>% summarise(n = n())
    ''')
"""

import os
from typing import Optional, Dict, Any
import snowflake.connector
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import serialization

# Check if rpy2 is available
try:
    import rpy2.robjects as ro
    from rpy2.robjects import pandas2ri
    from rpy2.robjects.conversion import localconverter
    RPY2_AVAILABLE = True
except ImportError:
    RPY2_AVAILABLE = False


class SnowflakeRBridge:
    """Bridge for R-Snowflake connectivity via Python."""
    
    def __init__(
        self,
        account: str,
        user: str,
        private_key_path: Optional[str] = None,
        password: Optional[str] = None,
        database: Optional[str] = None,
        schema: Optional[str] = None,
        warehouse: Optional[str] = None,
        role: Optional[str] = None
    ):
        """
        Initialize the Snowflake-R bridge.
        
        Args:
            account: Snowflake account identifier
            user: Snowflake username
            private_key_path: Path to RSA private key file (for key-pair auth)
            password: Password (alternative to key-pair auth)
            database: Default database
            schema: Default schema
            warehouse: Default warehouse
            role: Default role
        """
        self.account = account
        self.user = user
        self.database = database
        self.schema = schema
        self.warehouse = warehouse
        self.role = role
        
        # Set up authentication
        self.auth_params = {}
        if private_key_path:
            self.auth_params['private_key'] = self._load_private_key(private_key_path)
        elif password:
            self.auth_params['password'] = password
        else:
            # Try to use session token if in SPCS container
            token_path = "/snowflake/session/token"
            if os.path.exists(token_path):
                with open(token_path) as f:
                    self.auth_params['token'] = f.read().strip()
                self.auth_params['authenticator'] = 'oauth'
        
        self._conn = None
        
    def _load_private_key(self, key_path: str) -> bytes:
        """Load and convert private key to DER format."""
        with open(key_path, "rb") as f:
            p_key = serialization.load_pem_private_key(
                f.read(),
                password=None,
                backend=default_backend()
            )
        return p_key.private_bytes(
            encoding=serialization.Encoding.DER,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption()
        )
    
    def connect(self) -> snowflake.connector.SnowflakeConnection:
        """Establish connection to Snowflake."""
        if self._conn is None or self._conn.is_closed():
            conn_params = {
                'account': self.account,
                'user': self.user,
                **self.auth_params
            }
            if self.database:
                conn_params['database'] = self.database
            if self.schema:
                conn_params['schema'] = self.schema
            if self.warehouse:
                conn_params['warehouse'] = self.warehouse
            if self.role:
                conn_params['role'] = self.role
                
            self._conn = snowflake.connector.connect(**conn_params)
        return self._conn
    
    def close(self):
        """Close the Snowflake connection."""
        if self._conn and not self._conn.is_closed():
            self._conn.close()
    
    def query(self, sql: str) -> 'pandas.DataFrame':
        """
        Execute SQL query and return results as pandas DataFrame.
        
        Args:
            sql: SQL query to execute
            
        Returns:
            pandas DataFrame with query results
        """
        conn = self.connect()
        cur = conn.cursor()
        try:
            cur.execute(sql)
            # Use Arrow for high-performance fetch
            arrow_table = cur.fetch_arrow_all()
            return arrow_table.to_pandas()
        finally:
            cur.close()
    
    def query_to_r(self, sql: str, r_var_name: str) -> None:
        """
        Execute SQL query and make results available in R.
        
        Args:
            sql: SQL query to execute
            r_var_name: Name of the R variable to store results
        """
        if not RPY2_AVAILABLE:
            raise ImportError("rpy2 is not available. Install with: pip install rpy2")
        
        df = self.query(sql)
        
        with localconverter(ro.default_converter + pandas2ri.converter):
            r_df = ro.conversion.py2rpy(df)
            ro.globalenv[r_var_name] = r_df
        
        print(f"Query results stored in R variable: {r_var_name} ({len(df)} rows)")
    
    def run_r(self, r_code: str) -> Any:
        """
        Execute R code.
        
        Args:
            r_code: R code to execute
            
        Returns:
            Result of R code execution
        """
        if not RPY2_AVAILABLE:
            raise ImportError("rpy2 is not available. Install with: pip install rpy2")
        
        return ro.r(r_code)
    
    def r_result_to_python(self, r_var_name: str) -> 'pandas.DataFrame':
        """
        Get R dataframe as pandas DataFrame.
        
        Args:
            r_var_name: Name of R variable to convert
            
        Returns:
            pandas DataFrame
        """
        if not RPY2_AVAILABLE:
            raise ImportError("rpy2 is not available")
        
        r_obj = ro.globalenv[r_var_name]
        with localconverter(ro.default_converter + pandas2ri.converter):
            return ro.conversion.rpy2py(r_obj)
    
    def __enter__(self):
        self.connect()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()


# Convenience function for quick usage
def create_bridge_from_env() -> SnowflakeRBridge:
    """
    Create a SnowflakeRBridge using environment variables.
    
    Expected environment variables:
        SNOWFLAKE_ACCOUNT
        SNOWFLAKE_USER
        SNOWFLAKE_PRIVATE_KEY_PATH (or SNOWFLAKE_PASSWORD)
        SNOWFLAKE_DATABASE (optional)
        SNOWFLAKE_WAREHOUSE (optional)
    """
    return SnowflakeRBridge(
        account=os.environ['SNOWFLAKE_ACCOUNT'],
        user=os.environ['SNOWFLAKE_USER'],
        private_key_path=os.environ.get('SNOWFLAKE_PRIVATE_KEY_PATH'),
        password=os.environ.get('SNOWFLAKE_PASSWORD'),
        database=os.environ.get('SNOWFLAKE_DATABASE'),
        warehouse=os.environ.get('SNOWFLAKE_WAREHOUSE')
    )


if __name__ == "__main__":
    # Quick test
    print("Testing SnowflakeRBridge...")
    
    bridge = SnowflakeRBridge(
        account="ak32940",
        user="SIMON",
        private_key_path="/root/.snowflake/keys/simon_rsa_key.p8",
        database="SIMON",
        warehouse="SIMON_XS"
    )
    
    with bridge:
        # Test query
        df = bridge.query("SELECT current_user() as username, current_database() as db")
        print(f"Connected as: {df.iloc[0, 0]}")
        
        if RPY2_AVAILABLE:
            # Test R integration with smaller int values to avoid overflow
            bridge.query_to_r(
                "SELECT seq4() as id, uniform(1, 100, random())::int as value FROM TABLE(GENERATOR(ROWCOUNT=>10))",
                "test_data"
            )
            
            # Store result in a named variable
            bridge.run_r('''
                library(dplyr, quietly=TRUE, warn.conflicts=FALSE)
                summary_result <- test_data %>% 
                    summarise(n = n(), mean_val = mean(VALUE))
                print(summary_result)
            ''')
            
            # Get the result back
            result_df = bridge.r_result_to_python('summary_result')
            print("R processing result:")
            print(result_df)
    
    print("\nAll tests passed!")
