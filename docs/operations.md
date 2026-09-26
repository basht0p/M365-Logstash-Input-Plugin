# Checkpoints, delivery, and recovery

Each input maintains its own local H2 state database beneath `state_path`. Assign a unique directory to every tenant input. Keep it on durable local storage, include it in the service's backup/recovery plan, and preserve it when upgrading. Do not run two live Logstash instances against the same state directory.

At-least-once recovery after an abnormal shutdown requires **both** a durable, intact H2 state directory and a Logstash persistent queue configured with `queue.checkpoint.writes: 1`. These are mandatory prerequisites for the delivery guarantee:

```yaml
queue.type: persisted
queue.checkpoint.writes: 1
path.data: /var/lib/logstash
```

With the default or a larger persistent-queue checkpoint interval, Logstash may accept an event into memory while the plugin advances its H2 cursor; a crash before the queue checkpoint reaches disk can then lose that event because collection resumes after it. Keeping the H2 state directory on durable storage is also required: losing or rolling it back independently can invalidate collection progress. Under both prerequisites, crash recovery can replay events, so downstream duplicates remain possible. The plugin observes successful queue insertion only; it receives no downstream output acknowledgement and cannot guarantee exactly-once indexing.

Activity discovery advances in windows of up to 24 hours. Graph timestamp collectors use windows of up to one hour; a window that needs more pages than the per-window budget is split in half and retried, down to one minute, so a busy hour cannot stall collection. Configure `initial_lookback` and `overlap` for the expected restart and ingestion delay pattern, while staying within each source's retention limits.

**Late arrivals.** Each poll collects forward from the last committed position without re-reading it. Once per `overlap` period, a trailing sweep re-reads the last `2 × overlap + poll_interval` seconds, so records that become visible up to `overlap` seconds after their timestamp are still collected. Records that arrive later than that are picked up by reconciliation.

**Reconciliation.** Activity and timestamp-based Graph collectors re-read `replay_horizon` once per `reconciliation_interval`, one window per run. For configurations that enable Activity, the lookback and replay horizon cannot exceed seven days. These settings do not extend Microsoft source retention.

**Replay.** `replay_from` is a one-time replay point for time-window Graph collectors and Activity. The collector moves back to `replay_from` and re-emits every record from there up to where it was when the replay started, **even records it already delivered**. Use it to recover events lost downstream; the deterministic `@metadata.document_id` makes the re-sent events idempotent in the output. Changing `replay_from` to a new value starts a new replay. With Activity enabled, `replay_from` cannot be more than seven days ago.

**Source gaps.** The Activity API serves content for seven days. If discovery falls further behind than that (for example after a long outage), or a discovered blob expires before it is downloaded, the collector records a source gap, logs `Microsoft 365 source gap` with the skipped range or blob, increments the `gaps` metric, and continues from the oldest available content. Gaps are reported once; they are not retried.

**Content types.** Each Activity content type is collected independently. A failing type (for example a 403 on `DLP.All`) is reported and, for HTTP 400/401/403/404, retried after an hour, while the other types continue on schedule.

**Dedupe retention.** Delivered record identities are kept in the H2 state for at least 10 days, and longer when `replay_horizon + reconciliation_interval` requires it. There is no row limit: high-volume tenants store more entries rather than losing dedupe for records that can still be re-read. Entries for records that full listings (`risk_detection`, `risky_user`) keep returning are refreshed so they don't expire. Pruning runs at most hourly.

Use deterministic identifiers for downstream writes. `@metadata.document_id` changes with a source record version, so it preserves each version in append-only history. `@metadata.entity_id` stays stable for the same source entity and replaces prior versions in a current-state index. Snapshot hunting jobs are run-scoped; neither metadata ID remains stable across runs. Choose append-only history or current-state upserts according to the source:

- History retains every event; deduplicate by event ID.
- Current-state indexes replace the document with the same ID when a mutable alert, incident, or risk record changes.

The structured Microsoft response is always present under `microsoft.raw`. `preserve_original` controls an additional canonical JSON string (`event.original` in ECS v8 mode or `microsoft.original` in disabled mode). Source retention varies; checkpoint recovery cannot recover data the upstream API has already expired.

## Recovery checklist

1. Restore the tenant's state directory from the same Logstash data snapshot as appropriate, or preserve the current directory when restarting on the same host.
2. Check available disk space, ownership, file permissions, and whether another process owns the state directory.
3. Review Logstash logs and plugin metrics for authentication, consent, throttling, expired continuation links, API limits, and source licensing errors.
4. Confirm the required source records are still within the API's retention window. If events were lost downstream, set `replay_from` to re-send them (see **Replay** above); outputs that use `@metadata.document_id` absorb the re-sent copies.
5. Restart and verify events arrive from each enabled collector. Do not delete or recreate state as a routine troubleshooting step; that can trigger a broad replay or lose the prior checkpoint.

## Troubleshooting

| Symptom | Checks |
|---|---|
| `401` or token acquisition error | Tenant/client IDs, cloud, certificate registration and expiry, PFX password, host clock, secret availability, and correct Graph vs Activity audience. |
| `403` | App role is declared and admin consent is granted in the target tenant; verify the API is licensed and enabled. The log includes Microsoft's error code (for example `Authorization_RequestDenied`). The affected collector, or Activity content type, pauses for one hour before its next attempt. |
| `Microsoft 365 source gap` warning | The Activity API expired content before it was collected, usually after an outage of more than seven days. The skipped range or blob is in the log; collection has already moved on. |
| No activity records | Confirm subscriptions/content types and workload audit configuration. New subscriptions may take time to produce content; API retention limits apply. |
| `429` or `503` | Allow the plugin to honor server retry guidance; avoid adding parallel instances against the same tenant. |
| Repeated records | Expected after some crash windows. Use event IDs or deterministic document IDs in the output. |
| Checkpoint/storage errors | Check free space and permissions; preserve the state directory for investigation and recovery. |
| One collector fails | Validate its specific permission, consent, license, and cloud availability. Other collectors may continue independently. |

Per-collector metrics include `runs`, `errors`, `emitted`, `duplicates`, `gaps`, `throttles`, and `server_retries` counters plus `lag_seconds`, `last_success_epoch`, and `healthy` gauges. HTTP 400, 401, 403, and 404 errors pause only the affected collector (or Activity content type) for one hour before retry; other collectors continue. Monitor these metrics alongside Logstash queue and output health; successful queue insertion does not confirm downstream indexing. `max_workers` controls concurrent collectors and must be 1 through 16 (default 3).

Use the exact options and metrics available in the installed release; this page will be updated alongside implementation changes.
