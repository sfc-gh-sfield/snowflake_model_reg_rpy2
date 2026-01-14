#!/bin/bash
# Setup script for rpy2-based R model wrapper
# This script validates the environment for running the rpy2 implementation

set -e

echo "=========================================="
echo "rpy2 Environment Setup & Validation"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check Python
echo "Checking Python..."
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 --version 2>&1)
    check_pass "Python: $PYTHON_VERSION"
else
    check_fail "Python3 not found"
    exit 1
fi

# Check R
echo ""
echo "Checking R..."
if command -v R &> /dev/null; then
    R_VERSION=$(R --version | head -1)
    check_pass "R: $R_VERSION"
    
    # Check R_HOME
    R_HOME_VAL=$(R RHOME 2>/dev/null || echo "")
    if [ -n "$R_HOME_VAL" ]; then
        check_pass "R_HOME: $R_HOME_VAL"
    else
        check_warn "R_HOME not set - may need to export R_HOME"
    fi
else
    check_fail "R not found - install with: brew install r (macOS) or apt-get install r-base (Linux)"
    exit 1
fi

# Check R forecast package
echo ""
echo "Checking R packages..."
R_FORECAST_CHECK=$(Rscript -e "cat(requireNamespace('forecast', quietly=TRUE))" 2>/dev/null || echo "FALSE")
if [ "$R_FORECAST_CHECK" = "TRUE" ]; then
    FORECAST_VERSION=$(Rscript -e "cat(as.character(packageVersion('forecast')))" 2>/dev/null)
    check_pass "R forecast package: v$FORECAST_VERSION"
else
    check_warn "R forecast package not installed"
    echo "    Installing forecast package..."
    Rscript -e "install.packages('forecast', repos='https://cloud.r-project.org/', quiet=TRUE)"
    check_pass "R forecast package installed"
fi

# Check Python packages
echo ""
echo "Checking Python packages..."

# Check rpy2
python3 -c "import rpy2" 2>/dev/null && {
    RPY2_VERSION=$(python3 -c "import rpy2; print(rpy2.__version__)")
    check_pass "rpy2: v$RPY2_VERSION"
} || {
    check_fail "rpy2 not installed"
    echo "    Install with: pip install rpy2 OR conda install -c conda-forge rpy2"
    RPY2_MISSING=1
}

# Check pandas
python3 -c "import pandas" 2>/dev/null && {
    PANDAS_VERSION=$(python3 -c "import pandas; print(pandas.__version__)")
    check_pass "pandas: v$PANDAS_VERSION"
} || {
    check_fail "pandas not installed"
    PANDAS_MISSING=1
}

# Check numpy
python3 -c "import numpy" 2>/dev/null && {
    NUMPY_VERSION=$(python3 -c "import numpy; print(numpy.__version__)")
    check_pass "numpy: v$NUMPY_VERSION"
} || {
    check_fail "numpy not installed"
    NUMPY_MISSING=1
}

# Exit if critical packages missing
if [ -n "$RPY2_MISSING" ] || [ -n "$PANDAS_MISSING" ] || [ -n "$NUMPY_MISSING" ]; then
    echo ""
    check_fail "Missing required packages. Install with:"
    echo "    pip install rpy2 pandas numpy"
    echo "    OR"
    echo "    conda install -c conda-forge rpy2 pandas numpy"
    exit 1
fi

# Test rpy2 R integration
echo ""
echo "Testing rpy2 integration..."
python3 << 'EOF'
import sys
try:
    import rpy2.robjects as ro
    from rpy2.robjects.packages import importr
    
    # Test basic R evaluation
    result = ro.r('1 + 1')[0]
    assert result == 2, "Basic R evaluation failed"
    
    # Test package import
    base = importr('base')
    
    # Test forecast package
    forecast = importr('forecast')
    
    print("✓ rpy2 integration working correctly")
    sys.exit(0)
except Exception as e:
    print(f"✗ rpy2 integration test failed: {e}")
    sys.exit(1)
EOF

if [ $? -ne 0 ]; then
    check_fail "rpy2 integration test failed"
    exit 1
fi

# Check for model artifact
echo ""
echo "Checking for model artifact..."
MODEL_PATH="../dj_ml/arimax_model_artifact.rds"
if [ -f "$MODEL_PATH" ]; then
    check_pass "Model artifact found: $MODEL_PATH"
else
    check_warn "Model artifact not found at $MODEL_PATH"
    echo "    Run ../dj_ml/train_arimax.R to create the model"
fi

# Test prediction module
echo ""
echo "Testing prediction module..."
if [ -f "$MODEL_PATH" ]; then
    python3 << 'EOF'
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import numpy as np
    import pandas as pd
    from predict_arimax_rpy2 import load_arimax_model, predict_arimax_from_dataframe
    
    # Load model
    model = load_arimax_model('../dj_ml/arimax_model_artifact.rds')
    
    # Create test data
    np.random.seed(42)
    test_data = pd.DataFrame({
        'exog_var1': np.random.normal(5, 1, 5),
        'exog_var2': np.random.normal(10, 2, 5)
    })
    
    # Make predictions
    predictions = predict_arimax_from_dataframe(model, test_data)
    
    # Validate output
    assert len(predictions) == 5, "Wrong number of predictions"
    assert 'forecast' in predictions.columns, "Missing forecast column"
    assert 'lower_80' in predictions.columns, "Missing lower_80 column"
    
    print("✓ Prediction module test passed")
    print(f"  Sample prediction: {predictions['forecast'].iloc[0]:.4f}")
    sys.exit(0)
except Exception as e:
    print(f"✗ Prediction test failed: {e}")
    sys.exit(1)
EOF
    
    if [ $? -eq 0 ]; then
        check_pass "Prediction module working"
    else
        check_fail "Prediction module test failed"
    fi
else
    check_warn "Skipping prediction test - model not found"
fi

echo ""
echo "=========================================="
echo "Setup Summary"
echo "=========================================="
echo ""
echo "Environment is ready for rpy2-based R model scoring!"
echo ""
echo "Next steps:"
echo "  1. Open model_logging_rpy2.ipynb in Jupyter/Snowflake Notebooks"
echo "  2. Configure Snowflake connection"
echo "  3. Log model to registry with rpy2 dependencies"
echo ""
echo "Conda dependencies for Snowflake:"
echo '  conda_dependencies=["r-base>=4.1", "r-forecast", "rpy2>=3.5"]'
echo ""
