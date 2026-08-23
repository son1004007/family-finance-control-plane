# 08. Stop Asking for a Monthly Snapshot

A finance assistant becomes less useful when every analysis begins with a request for the user to re-enter balances and spending.

The next architecture step is therefore not another dashboard. It is a collection control plane.

## The operating model

```text
provider signal
  -> bounded collector
  -> source cursor + freshness
  -> staged observation
  -> reconciliation
  -> canonical finance history
  -> deterministic change metrics
```

The database now records not only a value but also whether the source that should refresh that value is current.

## Why staging matters

An email receipt and an account-balance API are both useful, but they are not equally authoritative. Treating every automated signal as ledger truth would create duplicate or contradictory transactions.

The collection model therefore assigns one of three authority levels:

- authoritative;
- reconciling;
- supplemental.

Collectors write only to staging tables. They cannot write the canonical transaction ledger.

## First connector: Gmail

The reusable Gmail collector uses `gmail.readonly`, performs a bounded initial synchronization, then stores Gmail `historyId` so later cycles fetch only changes.

Mail headers/snippets can be inspected in memory to match a rule, but raw mail text is not stored in the finance database. Persisted observations keep a hash, rule id, sender domain, event time, observation type and only explicitly configured normalized numeric fields.

## Egress without ingress

The collector needs outbound HTTPS. PostgreSQL does not.

The Compose overlay therefore attaches the collector to both the internal database network and a separate egress network, while the database stays internal-only. Neither service publishes a host port.

## The AI now asks a better question

Before:

> What is the household net worth?

Now:

> What is the household net worth, what changed, and are the sources that should refresh those values still fresh?

Two MCP tools were added for that distinction:

- `data_freshness`
- `change_summary`

This moves the project from a static financial snapshot toward a continuously maintained financial evidence system.
