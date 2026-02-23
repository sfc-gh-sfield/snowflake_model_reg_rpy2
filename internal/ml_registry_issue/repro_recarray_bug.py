"""
Reproduction: SPCS inference server recarray/fillna bug for R models
====================================================================

This script demonstrates that the SPCS inference server's recarray/fillna
crash is specific to R models, NOT a generic infrastructure issue.

It deploys two Python models:
  1. IdentityModel   -- all-float columns, returns input unchanged
  2. MixedTypeModel  -- mixed int/float columns (same schema as the R MPG model)

Both Python models work fine. The R model (deployed separately) fails with:
    recarray has no attribute fillna

This proves the bug is in how the inference server handles R model (rpy2)
data conversion, not in the numpy/pandas layer for Python models.

Prerequisites:
    pip install snowflake-ml-python cryptography PyJWT requests

Usage:
    python repro_recarray_bug.py --connection ak32940_remote_dev

    # Skip deploy if services already exist:
    python repro_recarray_bug.py --connection ak32940_remote_dev --skip-deploy

    # Clean up:
    python repro_recarray_bug.py --connection ak32940_remote_dev --cleanup
"""

import argparse
import hashlib
import base64
import json
import time
import sys

import pandas as pd
import requests
from snowflake.snowpark import Session
from snowflake.ml.registry import Registry
from snowflake.ml.model import custom_model


# =============================================================================
# 1. Test models
# =============================================================================

class IdentityModel(custom_model.CustomModel):
    """Returns the input unchanged. All-float columns."""

    @custom_model.inference_api
    def predict(self, input_df: pd.DataFrame) -> pd.DataFrame:
        return input_df


class MixedTypeModel(custom_model.CustomModel):
    """Accepts the same mixed int/float schema as the R MPG model.
    Returns a simple sum as the 'prediction' column.
    """

    @custom_model.inference_api
    def predict(self, input_df: pd.DataFrame) -> pd.DataFrame:
        result = input_df.select_dtypes(include="number").sum(axis=1)
        return pd.DataFrame({"prediction": result})


# =============================================================================
# 2. Connection helpers
# =============================================================================

def connect_keypair(account, user, private_key_path, **kwargs):
    """Connect using key-pair auth."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.backends import default_backend

    with open(private_key_path, "rb") as f:
        pk = serialization.load_pem_private_key(
            f.read(), password=None, backend=default_backend()
        )
    pk_bytes = pk.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    params = {"account": account, "user": user, "private_key": pk_bytes}
    params.update(kwargs)
    return Session.builder.configs(params).create()


def connect_from_toml(name=None):
    """Connect using connections.toml."""
    import os

    try:
        import tomllib  # Python 3.11+
    except ImportError:
        import tomli as tomllib  # pip install tomli for 3.10

    toml_path = os.path.join(
        os.environ.get("SNOWFLAKE_HOME", os.path.expanduser("~/.snowflake")),
        "connections.toml",
    )
    with open(toml_path, "rb") as f:
        cfg = tomllib.load(f)
    profile = cfg.get(name) if name else next(iter(cfg.values()))

    pk_path = profile.pop("private_key_path", None)
    profile.pop("authenticator", None)

    if pk_path:
        return connect_keypair(private_key_path=pk_path, **profile)
    else:
        return Session.builder.configs(profile).create()


def generate_jwt(session) -> str:
    """Generate a JWT for REST auth from the session's key-pair credentials."""
    import jwt as pyjwt
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.backends import default_backend

    conn_obj = session._conn._conn
    pk_data = conn_obj._private_key
    pk = serialization.load_der_private_key(
        pk_data, password=None, backend=default_backend()
    )
    pub = pk.public_key()
    pub_der = pub.public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    fp = base64.standard_b64encode(hashlib.sha256(pub_der).digest()).decode()
    account = session.get_current_account().strip('"').upper().replace(".", "-")
    user = session.get_current_user().strip('"').upper()

    now = int(time.time())
    payload = {
        "iss": f"{account}.{user}.SHA256:{fp}",
        "sub": f"{account}.{user}",
        "iat": now,
        "exp": now + 3600,
    }
    return pyjwt.encode(payload, pk, algorithm="RS256")


# =============================================================================
# 3. Helpers
# =============================================================================

def wait_for_service_endpoint(session, service_fqn, timeout_s=600):
    """Wait for a service to be READY and its ingress endpoint provisioned."""
    for i in range(timeout_s // 15):
        try:
            st = session.sql(
                f"SELECT SYSTEM$GET_SERVICE_STATUS('{service_fqn}')"
            ).collect()
            status_json = json.loads(st[0][0])
            status = status_json[0].get("status", "UNKNOWN") if status_json else "PENDING"
            msg = status_json[0].get("message", "") if status_json else ""
        except Exception:
            status, msg = "PENDING", "checking..."

        if status == "READY":
            # Check endpoint
            try:
                rows = session.sql(
                    f"SHOW ENDPOINTS IN SERVICE {service_fqn}"
                ).collect()
                ingress = rows[0]["ingress_url"] if rows else ""
                if ingress and "provisioning" not in ingress.lower():
                    return ingress
            except Exception:
                pass
        print(f"    [{(i+1)*15}s] {status} - {msg}")
        time.sleep(15)
    return None


def test_rest_endpoint(ingress, jwt_token, payload, label=""):
    """POST to the inference endpoint and return (status_code, body_text)."""
    url = f"https://{ingress}/predict"
    headers = {
        "Authorization": f'Snowflake Token="{jwt_token}"',
        "Content-Type": "application/json",
    }
    print(f"\n  [{label}] POST {url}")
    print(f"  Payload: {json.dumps(payload)[:200]}...")
    resp = requests.post(url, headers=headers, json=payload, timeout=30)
    print(f"  HTTP {resp.status_code}")
    body = resp.text[:600]
    print(f"  Body: {body}")

    if resp.status_code == 200:
        print(f"  --> PASS: Inference works for {label}")
    elif "recarray" in resp.text:
        print(f"  --> FAIL: recarray/fillna bug confirmed for {label}")
    else:
        print(f"  --> FAIL: Unexpected error for {label}")
    return resp.status_code, resp.text


# =============================================================================
# 4. Configuration
# =============================================================================

IDENTITY_MODEL_NAME = "REPRO_IDENTITY_MODEL"
IDENTITY_SERVICE = "repro_identity_svc"

MIXED_MODEL_NAME = "REPRO_MIXED_TYPE_MODEL"
MIXED_SERVICE = "repro_mixed_svc"

VERSION = "V1"

# Must exist in your account:
COMPUTE_POOL = "R_FORECAST_POOL"
IMAGE_REPO = "SIMON.SCRATCH.R_FORECAST_IMAGES"
DATABASE = "SIMON"
SCHEMA = "SCRATCH"
WAREHOUSE = "SIMON_XS"


# =============================================================================
# 5. Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Reproduce SPCS recarray/fillna bug (R-model specific)"
    )
    parser.add_argument("--connection", default="ak32940_remote_dev")
    parser.add_argument(
        "--skip-deploy", action="store_true",
        help="Skip model registration/deploy (services already exist)",
    )
    parser.add_argument(
        "--cleanup", action="store_true",
        help="Drop all test services and models, then exit",
    )
    parser.add_argument(
        "--r-service", default="MPG_SERVICE",
        help="Name of an existing R model service to test (default: MPG_SERVICE)",
    )
    args = parser.parse_args()

    print("=" * 70)
    print("REPRO: SPCS Inference Server recarray/fillna Bug")
    print("    (Demonstrating this is R-model specific)")
    print("=" * 70)

    # Connect
    print("\n[1] Connecting to Snowflake...")
    session = connect_from_toml(args.connection)
    session.sql(f"USE WAREHOUSE {WAREHOUSE}").collect()
    session.sql(f"USE DATABASE {DATABASE}").collect()
    session.sql(f"USE SCHEMA {SCHEMA}").collect()
    print(f"  Connected: {session.get_current_account()}")

    reg = Registry(session=session, database_name=DATABASE, schema_name=SCHEMA)

    # -- Cleanup mode --
    if args.cleanup:
        print("\n[CLEANUP] Dropping services and models...")
        for svc in [IDENTITY_SERVICE, MIXED_SERVICE]:
            session.sql(f"DROP SERVICE IF EXISTS {DATABASE}.{SCHEMA}.{svc}").collect()
            print(f"  Dropped service: {svc}")
        for model in [IDENTITY_MODEL_NAME, MIXED_MODEL_NAME]:
            try:
                reg.delete_model(model)
                print(f"  Deleted model: {model}")
            except Exception as e:
                print(f"  Model {model}: {e}")
        session.close()
        return

    # -- Deploy phase --
    if not args.skip_deploy:
        # ---- Identity model (all float) ----
        print(f"\n[2a] Registering {IDENTITY_MODEL_NAME} (all-float identity)...")
        sample_float = pd.DataFrame({
            "A": [1.0, 2.0, 3.0],
            "B": [4.0, 5.0, 6.0],
            "C": [7.0, 8.0, 9.0],
        })
        identity_model = IdentityModel()
        assert identity_model.predict(sample_float).shape == (3, 3)
        print("  Local predict OK")

        try:
            reg.delete_model(IDENTITY_MODEL_NAME)
        except Exception:
            pass
        mv_identity = reg.log_model(
            model=identity_model,
            model_name=IDENTITY_MODEL_NAME,
            version_name=VERSION,
            sample_input_data=sample_float,
        )
        print(f"  Registered {IDENTITY_MODEL_NAME}/{VERSION}")

        # ---- Mixed-type model (same schema as R MPG model) ----
        print(f"\n[2b] Registering {MIXED_MODEL_NAME} (mixed int/float)...")
        sample_mixed = pd.DataFrame({
            "CYL":  [6,     4,     8],
            "DISP": [160.0, 108.0, 360.0],
            "HP":   [110,   93,    245],
            "DRAT": [3.90,  3.85,  3.21],
            "WT":   [2.620, 2.320, 3.570],
            "QSEC": [16.46, 18.61, 15.84],
            "VS":   [0,     1,     0],
            "AM":   [1,     1,     0],
            "GEAR": [4,     4,     3],
            "CARB": [4,     1,     4],
        })
        mixed_model = MixedTypeModel()
        local_out = mixed_model.predict(sample_mixed)
        assert "prediction" in local_out.columns
        print(f"  Local predict OK: {local_out['prediction'].tolist()}")

        try:
            reg.delete_model(MIXED_MODEL_NAME)
        except Exception:
            pass
        mv_mixed = reg.log_model(
            model=mixed_model,
            model_name=MIXED_MODEL_NAME,
            version_name=VERSION,
            sample_input_data=sample_mixed,
        )
        print(f"  Registered {MIXED_MODEL_NAME}/{VERSION}")

        # ---- Deploy both ----
        for svc_name, mv_obj in [
            (IDENTITY_SERVICE, mv_identity),
            (MIXED_SERVICE, mv_mixed),
        ]:
            fqn = f"{DATABASE}.{SCHEMA}.{svc_name}"
            print(f"\n[3] Deploying {svc_name}...")
            session.sql(f"DROP SERVICE IF EXISTS {fqn}").collect()
            time.sleep(3)
            mv_obj.create_service(
                service_name=svc_name,
                image_build_compute_pool=COMPUTE_POOL,
                service_compute_pool=COMPUTE_POOL,
                image_repo=IMAGE_REPO,
                ingress_enabled=True,
            )
            print(f"  Service creation initiated for {svc_name}")

        # Wait for both endpoints
        print("\n[4] Waiting for service endpoints...")
        endpoints = {}
        for svc_name in [IDENTITY_SERVICE, MIXED_SERVICE]:
            fqn = f"{DATABASE}.{SCHEMA}.{svc_name}"
            print(f"\n  Waiting for {svc_name}...")
            ep = wait_for_service_endpoint(session, fqn)
            if ep:
                endpoints[svc_name] = ep
                print(f"  --> {svc_name} ready: {ep}")
            else:
                print(f"  --> TIMEOUT: {svc_name}")
    else:
        print("\n[2-4] Skipping deploy (--skip-deploy)")
        endpoints = {}
        for svc_name in [IDENTITY_SERVICE, MIXED_SERVICE]:
            try:
                rows = session.sql(
                    f"SHOW ENDPOINTS IN SERVICE {DATABASE}.{SCHEMA}.{svc_name}"
                ).collect()
                ingress = rows[0]["ingress_url"]
                if ingress and "provisioning" not in ingress.lower():
                    endpoints[svc_name] = ingress
                    print(f"  {svc_name}: {ingress}")
                else:
                    print(f"  {svc_name}: provisioning...")
            except Exception as e:
                print(f"  {svc_name}: {e}")

    # -- Test phase --
    print("\n" + "=" * 70)
    print("TESTING REST INFERENCE")
    print("=" * 70)

    jwt_token = generate_jwt(session)
    print(f"JWT generated (length={len(jwt_token)})")

    results = {}

    # Test 1: Identity model (all float)
    if IDENTITY_SERVICE in endpoints:
        payload_identity = {
            "dataframe_split": {
                "index": [0, 1],
                "columns": ["A", "B", "C"],
                "data": [[1.0, 4.0, 7.0], [2.0, 5.0, 8.0]],
            }
        }
        status, body = test_rest_endpoint(
            endpoints[IDENTITY_SERVICE], jwt_token, payload_identity,
            label="Python identity (all float)",
        )
        results["python_float"] = status

    # Test 2: Mixed-type Python model (same schema as R model)
    if MIXED_SERVICE in endpoints:
        payload_mixed = {
            "dataframe_split": {
                "index": [0],
                "columns": [
                    "CYL", "DISP", "HP", "DRAT", "WT",
                    "QSEC", "VS", "AM", "GEAR", "CARB",
                ],
                "data": [[6, 160.0, 110, 3.9, 2.62, 16.46, 0, 1, 4, 4]],
            }
        }
        status, body = test_rest_endpoint(
            endpoints[MIXED_SERVICE], jwt_token, payload_mixed,
            label="Python mixed-type (int+float)",
        )
        results["python_mixed"] = status

    # Test 3: R model service (if running)
    print(f"\n  Checking R model service: {args.r_service}...")
    try:
        r_fqn = f"{DATABASE}.{SCHEMA}.{args.r_service}"
        # Try to resume
        try:
            session.sql(f"ALTER SERVICE {r_fqn} RESUME").collect()
            print(f"  Resumed {args.r_service}")
            # Wait for ready
            ep = wait_for_service_endpoint(session, r_fqn, timeout_s=300)
        except Exception:
            rows = session.sql(f"SHOW ENDPOINTS IN SERVICE {r_fqn}").collect()
            ep = rows[0]["ingress_url"] if rows else None
            if ep and "provisioning" in ep.lower():
                ep = None

        if ep:
            status, body = test_rest_endpoint(
                ep, jwt_token, payload_mixed,
                label=f"R model ({args.r_service})",
            )
            results["r_model"] = status
        else:
            print(f"  R service not ready, skipping")
    except Exception as e:
        print(f"  R service check error: {e}")

    # -- Summary --
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    for label, status in results.items():
        marker = "PASS" if status == 200 else "FAIL"
        print(f"  [{marker}] {label}: HTTP {status}")

    if results.get("python_float") == 200 and results.get("python_mixed") == 200:
        if results.get("r_model") and results["r_model"] != 200:
            print("\n  CONCLUSION: Bug is R-MODEL SPECIFIC.")
            print("  Python models (even with identical schemas) work fine.")
            print("  The recarray/fillna crash is in the rpy2 model wrapper.")
        elif results.get("r_model") == 200:
            print("\n  CONCLUSION: Bug may have been fixed! R model also works.")
        else:
            print("\n  Python models work. R model not tested (service unavailable).")
    elif results.get("python_float") != 200:
        print("\n  CONCLUSION: Bug may affect ALL models (not just R).")
        print("  This would indicate a broader infrastructure issue.")

    session.close()
    print("\nDone.")


if __name__ == "__main__":
    main()
