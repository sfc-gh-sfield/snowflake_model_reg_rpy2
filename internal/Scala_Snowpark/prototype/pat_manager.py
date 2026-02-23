"""
PAT (Programmatic Access Token) Manager for Scala Prototype.

Slim copy of the PATManager from r_helpers.py, adapted for use with
the Scala/Snowpark integration prototype.

Usage:
    from pat_manager import PATManager
    pat_mgr = PATManager(session)
    pat_result = pat_mgr.create_pat(days_to_expiry=1, force_recreate=True)
    print(pat_result)
"""

import os
from datetime import datetime, timedelta
from typing import Optional, Dict, Any

PAT_TOKEN_NAME = "scala_pat"


class PATManager:
    """
    Manager for Programmatic Access Tokens (PAT).

    PATs provide short-lived authentication tokens that can be used
    by Scala/Snowpark to connect to Snowflake without the Workspace
    session's internal OAuth token.

    Example:
        >>> pat_mgr = PATManager(session)
        >>> pat_mgr.create_pat(days_to_expiry=1)
        >>> if pat_mgr.is_valid():
        ...     print("PAT is valid")
    """

    def __init__(self, session, token_name: str = PAT_TOKEN_NAME):
        self.session = session
        self.token_name = token_name
        self._token_secret: Optional[str] = None
        self._created_at: Optional[datetime] = None
        self._expires_at: Optional[datetime] = None
        self._role_restriction: Optional[str] = None
        self._user: Optional[str] = None

    @property
    def token(self) -> Optional[str]:
        return self._token_secret

    @property
    def is_expired(self) -> bool:
        if self._expires_at is None:
            return True
        return datetime.now() > self._expires_at

    def is_valid(self) -> bool:
        return self._token_secret is not None and not self.is_expired

    def time_remaining(self) -> Optional[timedelta]:
        if self._expires_at is None:
            return None
        remaining = self._expires_at - datetime.now()
        return remaining if remaining.total_seconds() > 0 else timedelta(0)

    def create_pat(
        self,
        days_to_expiry: int = 1,
        role_restriction: Optional[str] = None,
        network_policy_bypass_mins: int = 240,
        force_recreate: bool = False,
    ) -> Dict[str, Any]:
        """
        Create a new Programmatic Access Token.

        Args:
            days_to_expiry: Token validity in days
            role_restriction: Role to restrict token to (default: current)
            network_policy_bypass_mins: Minutes to bypass network policy
            force_recreate: Remove existing PAT first

        Returns:
            Dict with creation status and token info
        """
        result: Dict[str, Any] = {
            "success": False,
            "user": None,
            "role_restriction": None,
            "expires_at": None,
            "error": None,
        }

        try:
            self._user = (
                self.session.sql("SELECT CURRENT_USER()")
                .collect()[0][0]
            )
            result["user"] = self._user

            if role_restriction is None:
                role_restriction = (
                    self.session.get_current_role().replace('"', '')
                )
            self._role_restriction = role_restriction
            result["role_restriction"] = role_restriction

            if force_recreate:
                self.remove_pat()

            pat_result = self.session.sql(f"""
                ALTER USER {self._user}
                ADD PROGRAMMATIC ACCESS TOKEN {self.token_name}
                  ROLE_RESTRICTION = '{role_restriction}'
                  DAYS_TO_EXPIRY = {days_to_expiry}
                  MINS_TO_BYPASS_NETWORK_POLICY_REQUIREMENT = \
{network_policy_bypass_mins}
                  COMMENT = 'PAT for Scala/Snowpark from Workspace'
            """).collect()

            self._token_secret = pat_result[0]["token_secret"]
            self._created_at = datetime.now()
            self._expires_at = (
                self._created_at + timedelta(days=days_to_expiry)
            )

            os.environ["SNOWFLAKE_PAT"] = self._token_secret

            result["success"] = True
            result["expires_at"] = self._expires_at.isoformat()

        except Exception as e:
            error_msg = str(e)
            if "already exists" in error_msg.lower():
                result["error"] = (
                    f"PAT '{self.token_name}' already exists. "
                    "Use force_recreate=True to replace it."
                )
            else:
                result["error"] = error_msg

        return result

    def remove_pat(self) -> bool:
        try:
            if self._user is None:
                self._user = (
                    self.session.sql("SELECT CURRENT_USER()")
                    .collect()[0][0]
                )

            self.session.sql(f"""
                ALTER USER {self._user}
                REMOVE PROGRAMMATIC ACCESS TOKEN {self.token_name}
            """).collect()

            self._token_secret = None
            self._created_at = None
            self._expires_at = None

            if "SNOWFLAKE_PAT" in os.environ:
                del os.environ["SNOWFLAKE_PAT"]

            return True
        except Exception:
            return False

    def get_status(self) -> Dict[str, Any]:
        remaining = self.time_remaining()
        return {
            "exists": self._token_secret is not None,
            "is_valid": self.is_valid(),
            "user": self._user,
            "role_restriction": self._role_restriction,
            "created_at": (
                self._created_at.isoformat()
                if self._created_at else None
            ),
            "expires_at": (
                self._expires_at.isoformat()
                if self._expires_at else None
            ),
            "time_remaining": str(remaining) if remaining else None,
            "env_var_set": "SNOWFLAKE_PAT" in os.environ,
        }

    def refresh_if_needed(
        self, min_remaining_hours: float = 1.0
    ) -> Dict[str, Any]:
        """Refresh PAT if it's expired or close to expiring."""
        remaining = self.time_remaining()

        if remaining is None or remaining.total_seconds() == 0:
            return self.create_pat(force_recreate=True)

        hours_left = remaining.total_seconds() / 3600
        if hours_left < min_remaining_hours:
            return self.create_pat(force_recreate=True)

        return {
            "success": True,
            "refreshed": False,
            "hours_remaining": round(hours_left, 2),
        }
