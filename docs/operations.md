# Checkpoints, delivery, and recovery

Each input maintains its own local H2 state database beneath `state_path`. Assign a unique directory to every tenant input. Keep it on durable local storage, include it in the service's backup/recovery plan, and preserve it when upgrading. Do not run two live Logstash instances against the same state directory.

Collection is designed for at-least-once delivery when used with Logstash persistent queues and durable plugin state. Enable persistent queues and set `queue.checkpoint.writes: 1` when the strongest crash durability is required. A practical `logstash.yml` fragment is:

```yaml
queue.type: persisted
queue.checkpoint.writes: 1
path.data: /var/lib/logstash
```

The plugin can only treat successful insertion into the Logstash queue as delivery. It does not receive downstream output acknowledgements. A crash between queue insertion and checkpoint persistence can replay events, so downstream duplicates are possible. This setup does not provide exactly-once delivery.

Activity discovery advances in windows of up to 24 hours and depends on the Activity API's short content availability window; the current collector raises a visible availability-gap error when discovery falls more than seven days behind. Graph timestamp collectors use windows of up to one hour, with the configured overlap to account for late arrivals. Configure `initial_lookback` and `overlap` for the expected restart and ingestion delay pattern, while staying within each source's retention limits. `replay_from` is a one-time timestamp replay point for time-window Graph collectors and Activity. Activity and timestamp-based Graph collectors also perform bounded reconciliation using `replay_horizon` and `reconciliation_interval`; for configurations that enable Activity, the lookback and replay horizon cannot exceed seven days. These settings do not extend Microsoft source retention.

Use deterministic identifiers for downstream writes. `@metadata.document_id` changes with a source record version, so it preserves each version in append-only history. `@metadata.entity_id` stays stable for the same source entity and replaces prior versions in a current-state index. Snapshot hunting jobs are run-scoped; neither metadata ID remains stable across runs. Choose append-only history or current-state upserts according to the source:

- History retains every event; deduplicate by event ID.
- Current-state indexes replace the document with the same ID when a mutable alert, incident, or risk record changes.

The structured Microsoft response is always present under `microsoft.raw`. `preserve_original` controls an additional canonical JSON string (`event.original` in ECS v8 mode or `microsoft.original` in disabled mode). Source retention varies; checkpoint recovery cannot recover data the upstream API has already expired.

## Recovery checklist

1. Restore the tenant's state directory from the same Logstash data snapshot as appropriate, or preserve the current directory when restarting on the same host.
2. Check available disk space, ownership, file permissions, and whether another process owns the state directory.
3. Review Logstash logs and plugin metrics for authentication, consent, throttling, expired continuation links, API limits, and source licensing errors.
4. Confirm the required source records are still within the API's retention window. If replay is needed, follow the installed version's documented lookback/replay options and account for duplicates.
5. Restart and verify events arrive from each enabled collector. Do not delete or recreate state as a routine troubleshooting step; that can trigger a broad replay or lose the prior checkpoint.

## Troubleshooting

| Symptom | Checks |
|---|---|
| `401` or token acquisition error | Tenant/client IDs, cloud, certificate registration and expiry, PFX password, host clock, secret availability, and correct Graph vs Activity audience. |
| `403` | App role is declared and admin consent is granted in the target tenant; verify the API is licensed and enabled. The affected collector pauses for one hour before its next attempt. |
| No activity records | Confirm subscriptions/content types and workload audit configuration. New subscriptions may take time to produce content; API retention limits apply. |
| `429` or `503` | Allow the plugin to honor server retry guidance; avoid adding parallel instances against the same tenant. |
| Repeated records | Expected after some crash windows. Use event IDs or deterministic document IDs in the output. |
| Checkpoint/storage errors | Check free space and permissions; preserve the state directory for investigation and recovery. |
| One collector fails | Validate its specific permission, consent, license, and cloud availability. Other collectors may continue independently. |

Per-collector metrics include `runs`, `errors`, `emitted`, `duplicates`, `throttles`, and `server_retries` counters plus `lag_seconds`, `last_success_epoch`, and `healthy` gauges. HTTP 400, 401, 403, and 404 errors pause only the affected collector for one hour before retry; other collectors continue. Monitor these metrics alongside Logstash queue and output health; successful queue insertion does not confirm downstream indexing. `max_workers` controls concurrent collectors and must be 1 through 16 (default 3).

Use the exact options and metrics available in the installed release; this page will be updated alongside implementation changes.
