# Remote Development Setup for R + DuckDB Testing

This folder contains scripts and instructions for setting up a testing environment in Snowflake's ML Container Runtime using Remote Dev.

## Prerequisites

You need:
1. SnowCLI with the `remote_dev_prpr` branch
2. `websocat` installed locally
3. A Snowflake account with:
   - A compute pool (e.g., `STANDARD_1` or your own)
   - An External Access Integration (e.g., `ALLOW_ALL_INTEGRATION`)
   - A stage for persistence (e.g., `@MY_SSE_STAGE`)

## Step-by-Step Setup

### Step 1: Install SnowCLI Remote Dev Branch

```bash
# Clone and switch to remote_dev branch
git clone https://github.com/snowflakedb/snowflake-cli
cd snowflake-cli
git checkout remote_dev_prpr

# Install
pip install -U hatch
hatch build && pip install .

# Verify
snow --version
```

### Step 2: Configure Snowflake Connection

If you don't have a connection configured:

```bash
snow connection add
```

Your `~/.snowflake/config.toml` should look like:

```toml
default_connection_name = "my_connection"

[connections.my_connection]
host = "<YOUR_HOST>"
account = "<YOUR_ACCOUNT>"
user = "<YOUR_USER>"
password = "<YOUR_PASSWORD>"
warehouse = "<YOUR_WAREHOUSE>"
role = "<YOUR_ROLE>"
database = "<YOUR_DATABASE>"
schema = "<YOUR_SCHEMA>"
```

### Step 3: Install websocat

```bash
# macOS
brew install websocat

# Linux - download from https://github.com/vi/websocat/releases
```

### Step 4: Start Remote Dev Service

```bash
snow remote start \
  r_duckdb_dev \
  --compute-pool YOUR_COMPUTE_POOL \
  --eai-name ALLOW_ALL_INTEGRATION \
  --stage YOUR_SSE_STAGE \
  --ssh
```

Replace:
- `YOUR_COMPUTE_POOL` with your compute pool name
- `ALLOW_ALL_INTEGRATION` with your EAI name (or create one)
- `YOUR_SSE_STAGE` with your stage name

Wait for the service to start (may take 1-2 minutes).

### Step 5: Connect Cursor/VS Code

1. Open Cursor (or VS Code)
2. Install the **Remote-SSH** extension if not already installed
3. Press `Cmd/Ctrl + Shift + P`
4. Select **"Remote-SSH: Connect to Host"**
5. Choose `SNOW_REMOTE_ADMIN_R_DUCKDB_DEV` (matches your service name)
6. Wait for connection to establish

### Step 6: Open Working Directory

Once connected:
1. Press `Cmd/Ctrl + Shift + P`
2. Select **"File: Open Folder"**
3. Navigate to `/root/user-default/`
4. Click **OK**

This folder persists to your stage, so files survive restarts.

### Step 7: Upload Setup Script

From your local machine, copy the setup script to the remote:

**Option A: Via Cursor**
- Open `/root/user-default/` in Cursor
- Create a new file `setup_r_duckdb_env.sh`
- Paste the contents from `remote_dev/setup_r_duckdb_env.sh`

**Option B: Via Terminal (after connecting)**
```bash
# In the Cursor terminal (connected to remote)
curl -o setup_r_duckdb_env.sh https://raw.githubusercontent.com/sfc-gh-sfield/snowflake_model_reg_rpy2/main/remote_dev/setup_r_duckdb_env.sh
chmod +x setup_r_duckdb_env.sh
```

### Step 8: Run Setup Script

In the Cursor terminal (connected to remote):

```bash
cd /root/user-default
chmod +x setup_r_duckdb_env.sh

# Install everything (R + ADBC + DuckDB)
./setup_r_duckdb_env.sh --full
```

This will:
- Install micromamba
- Create R environment with tidyverse, DBI, dbplyr, duckdb, arrow
- Install ADBC Snowflake driver
- Set up symlinks for DuckDB
- Install DuckDB extensions (snowflake, httpfs, iceberg)

## Verifying the Installation

After setup completes, test in R:

```bash
# Activate environment
export MAMBA_ROOT_PREFIX=$HOME/micromamba
export PATH=$MAMBA_ROOT_PREFIX/bin:$PATH
eval "$($MAMBA_ROOT_PREFIX/bin/micromamba shell hook -s bash)"
micromamba activate r_env

# Start R
R
```

In R:
```r
library(DBI)
library(duckdb)
library(dplyr)
library(dbplyr)

# Connect to DuckDB
con <- dbConnect(duckdb::duckdb())

# Load Snowflake extension
DBI::dbExecute(con, "LOAD snowflake")

# Verify extension loaded
print("DuckDB + Snowflake extension ready!")
```

## Managing the Remote Service

```bash
# List running services
snow remote list

# Stop the service (when done)
snow remote stop r_duckdb_dev

# Restart later
snow remote start r_duckdb_dev --compute-pool YOUR_COMPUTE_POOL --eai-name ALLOW_ALL_INTEGRATION --stage YOUR_SSE_STAGE --ssh
```

## Files in This Directory

| File | Description |
|------|-------------|
| `setup_r_duckdb_env.sh` | Main setup script for R + DuckDB environment |
| `README.md` | This file |
| `test_duckdb_snowflake.R` | Test script (after setup) |

## Troubleshooting

### Connection refused
- Wait longer for service to start
- Check `snow remote list` to see service status

### Extension install fails
- Ensure EAI allows access to GitHub and conda-forge
- Check network connectivity: `curl -I https://github.com`

### DuckDB snowflake extension not loading
- Verify ADBC driver symlink exists
- Check DuckDB version matches symlink path
