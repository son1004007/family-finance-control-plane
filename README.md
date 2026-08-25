# Family Finance Control Plane

A self-hosted reference architecture for giving multiple AI clients a shared, evidence-backed and continuously refreshed view of household finance without relying on chat memory.

## Core separation

```text
Public GitHub
  reusable code / schema / docs / synthetic examples
        |
Private policy overlay
  household-specific decision rules, connector rules and private planning context
        |
Continuous collectors
  provider APIs / mail / files / optional device signals
        |
PostgreSQL + storage
  current and historical income / balances / transactions / assets / liabilities
        |
AI clients
  bounded direct SQL and/or curated MCP adapters
```

## Design principles

- GitHub stores code and decision-system definitions, not raw financial records.
- PostgreSQL is the Source of Truth for changing financial facts.
- Prefer automated acquisition over repeated manual household-data entry.
- Every automated source has provenance, a cursor, authority level and freshness SLA.
- Collection signals enter staging before they are promoted into canonical finance facts.
- Deterministic SQL views calculate financial metrics and changes before AI interpretation.
- Public examples are synthetic and reproducible.
- Private planning context is isolated from the public repository.
- Credentials, OAuth tokens, raw financial exports and database dumps with real rows never belong in Git.
- Missing financial/scenario values remain missing rather than being guessed as zero.

## Implemented capabilities

- PostgreSQL 16 canonical `ingest`, `finance`, `planning`, and `analytics` schemas
- time-versioned employment, account, asset and liability snapshots
- generic CSV and dependency-free XLSX import with source/mapping SHA-256 provenance
- import deduplication, row-level normalization status and optional fail-closed reconciliation
- NAS-style drop-folder archive/reject lifecycle
- continuous-source registry, collection runs, provider cursors and freshness SLA tracking
- authority-aware staged observations (`authoritative`, `reconciling`, `supplemental`)
- Gmail readonly collector with bounded initial sync and incremental `historyId` collection
- privacy-safe Galaxy notification relay with package-aware normalization and Google Drive `appDataFolder` transport
- stable Android release-signing path with production keys isolated in GitHub Actions secrets
- dedicated collector DB principal that cannot mutate the canonical finance ledger
- outbound-only collector network while PostgreSQL remains internal-only
- monthly cash flow and category spending
- current and historical net worth
- liquid reserve and emergency-reserve coverage
- latest net-worth and cash-flow change summary
- career/housing/childcare/commute household scenario outcomes
- broad local read-only AI SQL role plus separate narrower MCP-only role
- MCP 2.0 Streamable HTTP adapter with fixed read-only tools and no arbitrary SQL tool
- MCP tools for source freshness and latest financial changes
- PostgreSQL backup with mandatory isolated restore verification
- dry-run-first source-file retention cleanup
- public leak-prevention, database, ingestion, analytics, scenario, AI-access, MCP, collector and fresh-clone CI

## Quick start: synthetic end to end

Requirements:
- Docker with Compose
- POSIX shell

From a clean checkout:

```sh
sh scripts/run_synthetic_e2e.sh
```

The script uses a dedicated synthetic Compose project/container namespace and proves:

```text
DB bootstrap
 -> migrations
 -> fictional fixtures
 -> CSV/XLSX import
 -> deterministic analytics
 -> scenario calculation
 -> collection freshness/change views
 -> narrow MCP login
 -> internal MCP server
 -> MCP tool calls
```

It does not use or request real household data.

## Normal database bootstrap

For development without the MCP or collector services:

```sh
cp .env.example .env
# set a non-example POSTGRES_ADMIN_PASSWORD in .env
docker compose up -d db
sh scripts/migrate_compose.sh
```

The base Compose file publishes no PostgreSQL host port.

## Continuous collection

The long-term operating model is not repeated manual snapshots. Connectors periodically collect provider evidence and write only to staging through `finance_collector_client`.

The first reusable connector is Gmail. One-time Desktop OAuth grants only `gmail.readonly`; subsequent collection uses the stored refresh token and Gmail history cursor. Raw message bodies/subjects are not persisted by the default collector.

For institutions without a practical personal API, the Android notifier can normalize supported financial-app notifications on-device and relay only the structured event through the Google Drive `appDataFolder` boundary. Stable sideload signing and the one-time Windows bootstrap are documented in `docs/android-notifier-signing.md`.

See `docs/collection/continuous-collection.md` and `config/collector.example.json`.

`compose.collector.yaml` gives only the collector outbound Internet access. PostgreSQL stays on the internal Docker network and neither service publishes a host port.

## MCP boundary

`compose.mcp.yaml` is an overlay for the internal read-only MCP service. It publishes no host port and expects a separately provisioned `finance_mcp_client` credential that is a member only of `finance_mcp_reader`.

Remote AI connectivity is intentionally not enabled by the public runtime. A tunnel, reverse proxy, OAuth registration, DNS/public hostname, or other private-network bridge is a separate security decision.

See:
- `docs/security/mcp-threat-model.md`
- `docs/analytics/metric-definitions.md`
- `docs/collection/continuous-collection.md`
- `docs/android-notifier-signing.md`
- `docs/operations/disaster-recovery.md`
- `docs/operations/retention-policy.md`
- `docs/operations/dependency-policy.md`

## Build log

The sanitized build log under `docs/build-log/` records the architecture and implementation sequence using only fictional examples.

## Privacy model

This public repository intentionally contains no real household financial values or identifying details. Documentation and test fixtures use fictional values, role labels and synthetic locations. Real source exports, account identifiers, OAuth credentials, current balances and transactions are DATA-ONLY and remain in the private runtime boundary.
