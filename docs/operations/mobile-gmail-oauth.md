# Gmail OAuth from a mobile device through the Synology NAS

This flow keeps both the Google OAuth client JSON and the resulting Gmail token on the NAS. A mobile SSH client only forwards the loopback callback.

## Boundary

- OAuth client type: Desktop app
- Scope: `https://www.googleapis.com/auth/gmail.readonly`
- Callback listener: NAS `127.0.0.1:8765`
- Mobile device: forwards its own `127.0.0.1:8765` to the NAS through SSH
- No OAuth client secret or token is committed to Git

Google's installed-app loopback flow requires the application to listen on a loopback address. The SSH tunnel preserves that property while allowing the system browser on the mobile device to complete consent.

## NAS prerequisites

Place the downloaded Desktop OAuth client JSON at:

```text
/volume1/docker/family-finance/config/google-oauth-client.json
```

Set mode `0600`.

Install the auth-only Python dependencies in an isolated virtual environment under the Family Finance config/runtime area rather than the system Python environment.

## Authorization command

Run from the deployed public source directory on the NAS:

```sh
python scripts/authorize_gmail_collector.py \
  --client-secret /volume1/docker/family-finance/config/google-oauth-client.json \
  --output-token /volume1/docker/family-finance/config/gmail-token.json \
  --port 8765 \
  --no-browser
```

The command prints one `GMAIL_COLLECTOR_AUTH_URL=...` URL and waits for the callback.

## Mobile SSH forwarding

Keep a second SSH session open from the mobile device:

```sh
ssh -N -L 8765:127.0.0.1:8765 -p <NAS_SSH_PORT> <NAS_USER>@<NAS_HOST>
```

Open the printed Google authorization URL in the same mobile device's system browser, approve the requested Gmail read-only access, and allow the browser to return to `http://127.0.0.1:8765/`.

The browser callback traverses the SSH local forward to the NAS listener. On success the NAS command prints:

```text
GMAIL_COLLECTOR_AUTH=PASS
```

Afterward keep the token file mode at `0600`; do not copy its contents into chat, Git, issue trackers, or logs.
