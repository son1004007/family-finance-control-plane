# Bounded AI reader login

The database exposes no host port by default. A future MCP/API service running on the private Docker network still needs a real PostgreSQL login rather than the administration role.

`finance_ai_reader` remains a `NOLOGIN` group role. `scripts/provision_ai_reader_login.sh` creates a separate login role, by default `finance_ai_client`, and grants only membership in `finance_ai_reader`.

## Security properties

The login role is verified to have none of these PostgreSQL attributes:

- superuser;
- createdb;
- createrole;
- replication;
- bypass RLS.

It is explicitly removed from `finance_app` and `finance_ai_writer`, and is checked not to have INSERT privilege on planning tables.

Defense-in-depth role defaults include:

- `default_transaction_read_only=on`;
- bounded `statement_timeout`;
- bounded `lock_timeout`;
- bounded idle-in-transaction timeout;
- connection limit.

Privileges remain the primary security boundary; the read-only session default is an additional guardrail.

## Credential storage

The password is generated locally with OpenSSL and stored in a mode-0600 file outside Git. If the database role exists but that local credential file is missing, provisioning fails closed instead of silently rotating credentials.

The script never prints the generated password. TCP password authentication is tested inside the PostgreSQL container with the secret sent over stdin rather than included in a command-line argument.

Example generic invocation:

```sh
FINANCE_AI_SECRET_FILE=/private/path/ai-reader.env \
  sh scripts/provision_ai_reader_login.sh
```

On a self-hosted deployment, the private overlay chooses the actual secret path.

## Network boundary

Creating this login does **not** expose PostgreSQL. The reference Compose configuration keeps the database on the internal `finance_internal` network and publishes no database host port. Remote AI access requires a separately reviewed adapter such as an authenticated API or MCP service; do not open PostgreSQL directly to the internet.
