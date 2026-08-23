# MCP Threat Model

## Scope

The MCP adapter is a read-only presentation boundary over deterministic analytics. It is not a general database console and is not the Source of Truth.

```text
AI host/client
    |
    | MCP (only after an explicitly approved connectivity layer exists)
    v
Family Finance MCP
    |
    | finance_mcp_client
    v
finance_mcp_reader
    |
    v
curated analytics views
```

PostgreSQL and the MCP container have no host/public port in the reference Compose configuration.

## Protected assets

- current household financial facts
- normalized transaction ledger
- raw transaction descriptions/counterparties
- household planning assumptions
- database credentials
- private network topology
- import files and backups

## Trust boundaries

1. Raw financial files -> importer.
2. PostgreSQL facts -> curated analytics views.
3. Curated views -> MCP tool results.
4. MCP server -> external AI host, only after a separately approved tunnel/authentication boundary exists.

## Threats and controls

### Prompt injection / model-directed overreach

Threat: text in a conversation or imported source attempts to make an AI execute broader database actions.

Controls:
- no arbitrary SQL MCP tool exists;
- all MCP tools have fixed parameterized SQL statements;
- tools are annotated read-only/non-destructive;
- the MCP login is not a member of `finance_ai_reader`, `finance_ai_writer` or `finance_app`;
- the MCP group role has SELECT only on an explicit curated view allowlist.

### Raw-ledger exfiltration

Threat: a remote AI requests full transaction descriptions or counterparties.

Controls:
- `finance_mcp_reader` has no SELECT on `finance.transactions`;
- spending MCP output is category aggregate only;
- curated tool SQL names columns explicitly rather than using raw-table access;
- CI proves raw transaction SELECT fails as the MCP login.

### Credential leakage

Threat: DB passwords appear in Git, process output or model-visible tool results.

Controls:
- credentials are generated outside Git with mode `0600`;
- provisioning fails closed if a DB role exists but its local credential file is missing;
- production provisioning does not print the password;
- MCP tool errors return a generic query failure rather than database exception text;
- server logs record tool name/status/duration only, not tool arguments, SQL or financial values.

### Network exposure

Threat: PostgreSQL or MCP becomes reachable from untrusted networks.

Controls:
- base PostgreSQL Compose publishes no port;
- MCP overlay publishes no port;
- both use the internal Docker network;
- MCP Streamable HTTP enforces a Host allowlist/DNS-rebinding protection;
- external tunnel, reverse proxy, OAuth, DNS or public endpoint creation is outside the autonomous deployment and requires explicit approval.

### Denial of service / expensive queries

Controls:
- MCP DB login has a connection limit;
- statement, lock and idle-transaction timeouts are set at role/connection level;
- MCP request body is capped at 64 KiB;
- tool parameters bound lookback/limit ranges;
- response rows are capped;
- queries use deterministic views rather than model-generated SQL.

### Log/data residue

Controls:
- no prompts or database values are intentionally written to MCP application logs;
- container root filesystem is read-only;
- only a small `/tmp` tmpfs is writable;
- container drops all Linux capabilities and enables `no-new-privileges`.

### Stale or incomplete finance data

Threat: an AI treats incomplete ingestion as complete truth.

Controls:
- provenance and import status are stored;
- reconciliation mismatch fails closed before transaction writes;
- missing scenario values remain missing;
- metric documentation distinguishes "recorded activity" from actual total household activity.

## External connectivity gate

Local/internal MCP implementation is not approval to expose it externally.

Before connecting a remote AI host, separately decide and verify:
- supported remote-MCP mechanism for that AI host;
- authentication/authorization model;
- tunnel/reverse-proxy ownership and termination point;
- expected hostname and MCP Host allowlist;
- audit/incident-revocation procedure;
- least-privilege client scope.

OpenAI currently documents that ChatGPT connects to remote MCP servers rather than directly to local MCP servers and provides Secure MCP Tunnel for supported private/on-premises deployments. Product availability can vary by plan/workspace, so verify current product documentation at connection time.

References:
- Model Context Protocol Python SDK: https://github.com/modelcontextprotocol/python-sdk
- MCP transport/deployment guidance: https://github.com/modelcontextprotocol/python-sdk/blob/main/docs/run/deploy.md
- OpenAI developer mode/MCP apps: https://help.openai.com/en/articles/12584461
