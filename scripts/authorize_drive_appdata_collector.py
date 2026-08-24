#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path

from google_auth_oauthlib.flow import InstalledAppFlow

SCOPES = ["https://www.googleapis.com/auth/drive.appdata"]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Authorize the Family Finance Drive AppData relay with drive.appdata only."
    )
    parser.add_argument("--client-secret", required=True, help="Google Desktop OAuth client JSON")
    parser.add_argument("--output-token", required=True, help="Token JSON output path")
    parser.add_argument(
        "--port",
        type=int,
        default=8766,
        help="Loopback callback port.",
    )
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Print the authorization URL instead of opening a browser on this host.",
    )
    args = parser.parse_args()

    if not 1024 <= args.port <= 65535:
        raise SystemExit("--port must be between 1024 and 65535")

    client_secret = Path(args.client_secret).expanduser().resolve()
    output = Path(args.output_token).expanduser().resolve()
    if not client_secret.is_file():
        raise SystemExit("client secret JSON does not exist")
    if client_secret == output:
        raise SystemExit("client secret and output token paths must differ")

    flow = InstalledAppFlow.from_client_secrets_file(str(client_secret), SCOPES)
    credentials = flow.run_local_server(
        host="127.0.0.1",
        port=args.port,
        open_browser=not args.no_browser,
        authorization_prompt_message="DRIVE_APPDATA_AUTH_URL={url}",
        success_message="Family Finance Drive AppData authorization completed. You may close this tab.",
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    old_umask = os.umask(0o077)
    try:
        output.write_text(credentials.to_json(), encoding="utf-8")
        output.chmod(0o600)
    finally:
        os.umask(old_umask)
    print(f"DRIVE_APPDATA_AUTH=PASS token_file={output}")
    print("OAuth client secret and token are DATA-ONLY. Never commit either file to Git.")


if __name__ == "__main__":
    main()
