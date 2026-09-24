# Architecture and release gates

The input is organized around one Logstash input instance per tenant. The instance authenticates independently, creates resource-specific Graph and Activity API clients, schedules enabled REST collectors, and writes each tenant's checkpoints to a local H2 database. Collector definitions and cloud endpoints are shared through `data/collector_manifest.json`, which is also consumed by the tenant provisioning helper.

The Activity collector subscribes to selected content types, discovers available content in bounded time windows, records pending blobs in local state, then downloads and emits records. Graph collectors page through API responses and maintain per-collector progress; mutable alerts, incidents, and risk entities need version-aware duplicate handling. Advanced Hunting uses named jobs with explicit incremental or snapshot semantics. In ECS v8 mode, the emitter maps common fields and keeps Microsoft data under `microsoft.raw`; disabled mode retains the Microsoft namespace without ECS mappings. `@metadata.document_id` is version-specific for history, while `@metadata.entity_id` is stable across versions for current-state upserts.

The state directory is the local recovery boundary. It is tenant/cloud scoped and locked against concurrent ownership. Back it up and retain it with Logstash's persistent queue. The plugin can observe queue acceptance, not downstream output acknowledgement. Crashes around queue/state writes can lead to replayed duplicates; configure outputs for stable IDs where appropriate. This design is at-least-once under its durability prerequisites, never an exactly-once guarantee.

## Release gates

Before a production release, record evidence for all of the following:

- Automated tests cover authentication/config validation, collector pagination and failures, duplicate and checkpoint behavior, shutdown, and helper idempotency/secret redaction.
- Pipelines start and run on the exact supported Logstash 8.19 and 9.x versions, including the packaged Java dependencies.
- Controlled restarts, persistent queue replay, delayed records, throttling, and state backup/restore are exercised.
- A commercial tenant pilot runs for 48 hours with expected events reconciled against source systems.
- GCC, GCC High, and DoD cloud smoke tests are performed in authorized tenants before those profiles are represented as verified.
- Licensing and source availability are confirmed for each collector the release documents.

The current evidence and outstanding gates are tracked in [validation status](validation-status.md).
