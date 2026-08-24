# Android financial notification relay

This optional companion covers financial institutions that do not expose a safe individual customer API.

## Design

```text
Android financial app notification
  -> NotificationListenerService
  -> in-memory normalization only
  -> app-private normalized event queue
  -> WorkManager
  -> Google Drive appDataFolder (drive.appdata only)
  -> outbound-only NAS collector
  -> ingest.collection_observations (supplemental)
  -> reconciliation with stronger sources
```

The relay is deliberately **supplemental**, not authoritative. A notification can be missing, delayed, duplicated, truncated, or formatted differently after an institution app update. Official provider APIs, statements, and reconciled account records remain stronger evidence.

## Privacy boundary

Raw notification title/text must not leave the Android process normalization step and must never be written to Drive, Git, PostgreSQL, logs, crash messages, or the app-private queue.

The durable relay contract contains only:

- stable event hash input / event identifier;
- event time;
- normalized event type;
- unsigned amount magnitude and currency;
- debit/credit/neutral/unknown direction;
- source Android package;
- optional normalized merchant key;
- optional user-defined local account alias;
- parser confidence.

Account/card/phone numbers and raw notification fields are rejected by the NAS parser. The device identifier is hashed before it is persisted in the observation payload.

## Google relay boundary

The companion requests only:

`https://www.googleapis.com/auth/drive.appdata`

This is the narrow Google Drive application-data scope. Files are created in `appDataFolder`, which is hidden from the normal Drive UI and inaccessible to other Drive applications. No general `drive`, `drive.readonly`, or Gmail scope is requested by the Android companion.

The Android OAuth client and the NAS-side Desktop OAuth client for this relay should be configured under the same Google Cloud application/project and use the same Google account. Cross-client visibility of the intended app-data space must be proven by the bounded E2E test before the relay is treated as live.

## Reliability

- Each normalized notification is first stored in app-private storage.
- An immediate unique WorkManager job is queued whenever a financial event is normalized.
- A 15-minute periodic WorkManager job is the safety retry.
- Upload requires an active network.
- A Drive batch is deleted only after the NAS has durably staged it.
- If Drive acknowledgement fails after staging, the file is deliberately retained and the database deduplicates the next poll by `external_event_hash`.
- No notification listener or relay endpoint is exposed from the NAS.

Samsung may place infrequently used applications into sleeping/deep-sleep modes. On Galaxy devices the companion should be added once to **Settings -> Device care -> Battery -> Background usage limits -> Never sleeping apps**. The app includes Samsung's documented deep link when available.

## Event semantics

Notifications should model movement separately from consumption. In particular, a bank debit that automatically charges an intermediate wallet is not itself household spending.

Example:

```text
Bank account       -100000  account_debit / wallet funding evidence
Wallet             +100000  wallet_charge
Wallet              -38000  wallet_purchase / actual consumption evidence
```

Reconciliation can later pair the bank debit and wallet charge as an internal transfer and use the wallet purchase (plus a merchant receipt when available) as spending. This prevents double-counting wallet auto-charge amounts.

## User-owned activation gates

Repository, CI, NAS staging, and safety boundaries should be completed before asking for these steps.

1. Install a consistently signed companion APK on the Android device.
2. Register the Android OAuth client for `io.familyfinance.notifier` with the APK signing certificate fingerprint in the same Google Cloud project used for the relay.
3. Add `drive.appdata` to the OAuth consent configuration and authorize it in the companion.
4. Grant Android notification access.
5. Add the companion to Samsung Never sleeping apps.
6. Authorize a NAS Desktop OAuth token with `drive.appdata` only and store it as DATA-ONLY.

Passwords, OTPs, banking certificates, account credentials, full card numbers, and raw notification exports are not required.

## Acceptance criteria

The relay becomes live only when a synthetic or real bounded notification produces all of the following without raw-text leakage:

- Android event queued and uploaded;
- NAS Drive source collection succeeds;
- one deduplicated `supplemental` observation is staged;
- source freshness becomes `fresh`;
- Gmail collection remains healthy;
- PostgreSQL, MCP, and collector still publish no new host ports;
- collector still cannot mutate canonical ledger tables.
