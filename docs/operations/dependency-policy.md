# Dependency and Update Policy

This project favors explicit, reviewable version changes over floating runtime dependencies.

## Runtime pins

Current reference pins include:
- PostgreSQL: `postgres:16.15-alpine`
- MCP runtime Python: `python:3.12.14-slim-bookworm`
- MCP Python SDK: `mcp==2.0.0`
- Psycopg: `psycopg[binary]==3.3.4`
- GitHub checkout action: immutable commit for the selected release

The generic CSV/XLSX normalizers use a disposable pinned Python major/minor image and standard-library code; no host Python package installation is required for normal imports.

## Update rules

1. Do not replace runtime images or packages with `latest`.
2. Review upstream release/security notes before a version bump.
3. Change one dependency family at a time where practical.
4. Run the full public CI matrix, especially fresh-clone E2E and MCP Streamable HTTP contract.
5. For database patch/minor updates, verify backup and isolated restore before live rollout.
6. For MCP SDK changes, re-check protocol revision, transport options, tool annotation field names and remote-host compatibility.
7. Only after CI passes should the private NAS deployment consume the new public SHA.

## MCP-specific compatibility

The MCP Python SDK 2.x is a breaking rewrite relative to 1.x and targets the 2026-07-28 protocol while retaining compatibility paths for older clients. The project therefore pins 2.0.0 rather than allowing an unbounded major update.

References:
- https://github.com/modelcontextprotocol/python-sdk
- https://www.postgresql.org/docs/16/
- https://www.psycopg.org/psycopg3/docs/
- https://hub.docker.com/_/postgres
- https://hub.docker.com/_/python

## Automated dependency bots

Automated dependency PRs are acceptable if they preserve the rules above, but automatic merging is not. A version change is complete only when the normal regression suite and private deployment evidence are green.
