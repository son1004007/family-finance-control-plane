from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "collector"))

from family_finance_collector.main import _optional_nonempty_path


def test_missing_or_empty_token_is_auth_pending() -> None:
    old = os.environ.get("DRIVE_APPDATA_TOKEN_FILE")
    try:
        os.environ.pop("DRIVE_APPDATA_TOKEN_FILE", None)
        assert _optional_nonempty_path("DRIVE_APPDATA_TOKEN_FILE") is None
        with tempfile.TemporaryDirectory() as tmp:
            token = Path(tmp) / "drive-token.json"
            token.write_bytes(b"")
            os.environ["DRIVE_APPDATA_TOKEN_FILE"] = str(token)
            assert _optional_nonempty_path("DRIVE_APPDATA_TOKEN_FILE") is None
            token.write_text("{}", encoding="utf-8")
            assert _optional_nonempty_path("DRIVE_APPDATA_TOKEN_FILE") == token
    finally:
        if old is None:
            os.environ.pop("DRIVE_APPDATA_TOKEN_FILE", None)
        else:
            os.environ["DRIVE_APPDATA_TOKEN_FILE"] = old


if __name__ == "__main__":
    test_missing_or_empty_token_is_auth_pending()
    print("COLLECTOR_AUTH_PENDING_TESTS=PASS")
