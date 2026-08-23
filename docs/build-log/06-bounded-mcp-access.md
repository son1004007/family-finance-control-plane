# 06. Giving AI Access Without Giving It a Database Console

A local AI agent can be given a read-only PostgreSQL account. A remote AI host needs a different boundary.

The project therefore uses two separate concepts:

```text
local direct SQL
  -> finance_ai_client
  -> broader read-only finance/analytics access

remote/adapter MCP
  -> finance_mcp_client
  -> finance_mcp_reader
  -> curated analytics views only
```

## What the MCP server exposes

The initial tool surface is deliberately small:

- list households
- current financial snapshot
- monthly cash flow
- spending summary by category
- net-worth history
- emergency-reserve coverage
- scenario outcomes

There is no `execute_sql`, `query_sql` or similar tool.

## Defense in depth

Application-level fixed queries are not the only control. The PostgreSQL principal itself cannot select the raw transaction table and is not a member of the broader reader/writer/application roles.

Additional controls include:
- parameterized SQL;
- default read-only transactions;
- connection/statement/lock/idle timeouts;
- request and response size bounds;
- read-only/non-destructive MCP annotations;
- metadata-only tool logging;
- read-only container filesystem;
- dropped Linux capabilities;
- no host port in Compose;
- DNS-rebinding Host allowlist.

## Current transport

The implementation uses MCP Python SDK 2.0 and stateless Streamable HTTP with JSON responses. The service is intended to run inside the private Docker network.

The fact that an HTTP server exists does **not** mean it is internet-facing. External tunnel/reverse-proxy/OAuth configuration is intentionally a separate approval gate.

## Testing

CI starts PostgreSQL, provisions the narrow MCP login, builds the container, calls the actual Streamable HTTP endpoint with the official MCP Client, checks deterministic synthetic values, then proves the same database principal cannot read raw transactions or mutate data.

This keeps AI convenience on top of a database-enforced security boundary rather than trusting prompt instructions alone.
