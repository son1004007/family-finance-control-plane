# Continuous collection

The control plane is designed to answer two different questions:

1. what was the household position at a particular point in time?
2. what has changed since the last trustworthy observation?

A manually entered baseline can help with the first question, but it must not be the default long-term operating model. The preferred model is continuous, source-aware acquisition with explicit freshness and provenance.

## Pipeline

```text
source
  -> connector
  -> collection run + cursor
  -> staged observation
  -> reconciliation / promotion policy
  -> canonical finance snapshots and transactions
  -> deterministic change analytics
  -> AI interpretation
```

Collectors never receive the database owner credential. They use a dedicated `finance_collector_client` login that can write only the collection staging model and cannot mutate `finance.transactions`, assets, liabilities, income, or planning data.

## Source authority

Every collection source and observation has an authority level.

| Level | Intended examples | Default behavior |
|---|---|---|
| `authoritative` | institution account/broker API or another contractually authoritative source | eligible for controlled automatic promotion after adapter-specific reconciliation |
| `reconciling` | official statement, tax notice, billing statement | compare with canonical facts and flag differences; do not silently overwrite stronger facts |
| `supplemental` | merchant receipts, app notifications | enrich classification/change detection; never define account balance by itself |

The distinction is required because a purchase receipt, card notification, statement, and account API may refer to the same economic event but have different completeness and timing.

## Gmail connector

The first reusable connector is Gmail because many institutions and merchants emit recurring statements, notices, receipts, and account reports by email.

The connector uses only:

```text
https://www.googleapis.com/auth/gmail.readonly
```

Initial authorization is one-time Desktop OAuth. The resulting refresh token is DATA-ONLY and must be stored outside Git with mode `0600`.

```sh
python -m pip install -r collector/requirements-auth.txt
python scripts/authorize_gmail_collector.py \
  --client-secret /private/path/client_secret.json \
  --output-token /private/path/gmail-token.json
```

Initial collection uses a bounded Gmail search query. Subsequent collection stores Gmail `historyId` as a cursor and requests only mailbox changes. If Gmail reports that an old history cursor is no longer valid, the connector performs the configured bounded full synchronization and establishes a new cursor.

### Privacy behavior

Matching may inspect `From`, `Subject`, and Gmail `snippet` in memory. By default the collector does **not** persist the raw subject, snippet, body, recipient list, attachment content, or Gmail message id.

A staged observation stores only values such as:

- SHA-256 event fingerprint;
- matching rule id;
- sender domain;
- observation type;
- event timestamp;
- configured amount/currency extraction when a rule is sufficiently specific;
- source authority and promotion status.

This makes email a signal/provenance source rather than a second raw mailbox archive.

## Network boundary

`compose.collector.yaml` gives the collector two networks:

- `finance_internal`: private path to PostgreSQL;
- `collector_egress`: outbound Internet access needed for provider APIs.

PostgreSQL remains attached only to `finance_internal`. The collector publishes no host port. Adding outbound collection therefore does not create a new inbound NAS endpoint.

## Freshness

`ingest.collection_sources` records:

- configured cadence;
- freshness SLA;
- last attempt;
- last successful collection;
- current cursor;
- last error type.

`analytics.v_collection_source_freshness` classifies each source as:

- `fresh`;
- `stale`;
- `never_collected`;
- `disabled`.

AI clients should call the MCP `data_freshness` tool before making a decision that depends on current values.

## Change analysis

Canonical historical facts remain separate from source observations. Once authoritative/reconciled data reaches the canonical model, deterministic views calculate net-worth history and cash-flow history.

`analytics.v_household_change_summary_by_currency` exposes the latest:

- net worth;
- month-over-month net-worth change;
- net cash flow;
- prior-month net cash flow;
- net-cash-flow change.

The MCP `change_summary` tool exposes the same calculation to AI clients.

## Adding another connector

A connector should implement the same contract rather than writing directly to the ledger:

1. maintain a provider cursor or bounded polling interval;
2. record every collection attempt in `ingest.collection_runs`;
3. deduplicate observations using a stable external-event hash;
4. persist only the minimum normalized evidence required for reconciliation;
5. classify authority explicitly;
6. never log provider tokens or financial payloads;
7. keep credentials outside Git;
8. use the collector DB principal, not admin or AI credentials.

Institution-specific promotion into canonical transactions/balances should have its own deterministic reconciliation tests.

## Provider reality

Not every useful source has a consumer-grade production API. In particular, Korean Open Banking/MyData interfaces involve institution/business registration and contracts rather than functioning as a universal personal developer credential. The architecture therefore supports multiple acquisition paths instead of depending on a single aggregator:

- provider/broker APIs where individual API access exists;
- Gmail statements/notices/receipts;
- exported statements as a fallback and reconciliation input;
- optional device-side event collection such as Android financial-app notifications, subject to a separate device permission and private sync design.
