#!/bin/bash

echo "========================================="
echo "R ARIMAX Model - Snowflake Registry Demo"
echo "========================================="
echo ""

echo "Step 1: Checking if R is installed..."
if command -v Rscript &> /dev/null; then
    echo "✓ R found: $(Rscript --version 2>&1 | head -1)"
else
    echo "✗ R not found. Please install R first:"
    echo "  macOS: brew install r"
    echo "  Linux: sudo apt-get install r-base"
    exit 1
fi

echo ""
echo "Step 2: Installing required R packages (forecast)..."
Rscript -e "if (!require('forecast', quietly = TRUE)) install.packages('forecast', repos='http://cran.rstudio.com/')"

echo ""
echo "Step 3: Training ARIMAX model..."
Rscript train_arimax.R

if [ -f "arimax_model_artifact.rds" ]; then
    echo "✓ Model file created: arimax_model_artifact.rds"
else
    echo "✗ Model file not created"
    exit 1
fi

echo ""
echo "Step 4: Testing R prediction script..."
cat > test_input.csv << EOF
exog_var1,exog_var2
5.2,10.5
4.8,9.8
5.5,11.2
EOF

Rscript predict_arimax.R arimax_model_artifact.rds test_input.csv test_output.csv

if [ -f "test_output.csv" ]; then
    echo "✓ Predictions generated successfully"
    echo ""
    echo "Sample predictions:"
    head -5 test_output.csv
    rm test_input.csv test_output.csv
else
    echo "✗ Predictions failed"
    exit 1
fi

echo ""
echo "========================================="
echo "✓ Setup Complete!"
echo "========================================="
echo ""
echo "Files created:"
echo "  - arimax_model_artifact.rds (trained R model)"
echo "  - train_arimax.R (model training script)"
echo "  - predict_arimax.R (prediction script)"
echo "  - r_model_wrapper.py (Python wrapper class)"
echo "  - model_logging.ipynb (demo notebook)"
echo ""
echo "Next steps:"
echo "  1. Open model_logging.ipynb in Jupyter/Snowflake notebook"
echo "  2. Run cells to log model to Snowflake Registry"
echo "  3. Use SNOWPARK_CONTAINER_SERVICES target platform"
echo ""
