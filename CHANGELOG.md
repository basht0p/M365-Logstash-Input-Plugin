# Changelog

## [1.0.2]

Security release. Pull the new images, or install the new offline pack on Logstash 9.5.6 / 8.19.24.

- The container images are built on Logstash 9.5.6 and 8.19.24, which remove the compromised eMudhra root certificates from the image's OS certificate bundle and the bundled JDK trust store (ESA-2026-237 / CVE-2026-115714, ESA-2026-228). The plugin's token and API requests trust those stores, so the 1.0.1 images (Logstash 9.5.4 / 8.19.22) should be replaced. The image tags are now `1.0.2-logstash-9.5.6` and `1.0.2-logstash-8.19.24`. If you install the plugin on your own Logstash, upgrade Logstash itself to 9.5.6 / 8.19.24.
- The vendored jackson-core, jackson-databind, and jackson-annotations are pinned to 2.18.11 instead of the 2.18.1 that msal4j 1.22.0 resolves, which fixes CVE-2026-89425, CVE-2026-89407, CVE-2026-68494, CVE-2026-18401, CVE-2026-68497, CVE-2026-83557, CVE-2026-19032, and CVE-2026-59889. The plugin doesn't use the affected parser features.
- CI and the offline packs target Logstash 8.19.24 and 9.5.6.

## [1.0.1]

- The H2 state file no longer grows without bound on busy tenants. Pruning removed expired dedupe entries, but H2 never released the freed space while the database was open, and each per-record commit left tens of kilobytes of superseded pages behind; in a test, about 15,000 live entries took up 3 GB. The input now compacts the file with `SHUTDOWN COMPACT` after the first pruning pass following startup, and again whenever the file has grown by 256 MB since the last compaction, then reopens it. Existing oversized state files shrink shortly after the first collector run following the upgrade.

## [1.0.0]

First stable release. It has been validated on live Commercial Microsoft 365 tenants; GCC, GCC High, and DoD haven't been tested yet.

- The container image's JVM starts with a 256 MB heap that grows to the stock 1 GB maximum under load and shrinks again when idle, and glibc is limited to two malloc arenas. In CI, a burst of 1 million events peaked at 656–683 MiB and settled at 528–550 MiB, against about 1,150 MiB for the stock Logstash images, with the same throughput. `LS_JAVA_OPTS` still overrides these settings.
- The container image is built on `docker.elastic.co/logstash/logstash-oss` instead of the default Logstash image, which leaves out X-Pack and the Elastic-licensed plugins. Pipelines that use `xpack.*` settings or the `elastic_integration` filter should install the offline pack on the default distribution instead.
- `Initialize-M365LogstashTenant.ps1` records each run in a single `provisioning_result.json` (IDs, permissions, consented roles, validation results, credential expiry, generated file paths, and credential import steps) and prints only that file's path instead of a nested table. It replaces `provisioning-report.json` and `credential-import.txt`.

## [0.1.1]

- `Dockerfile` that builds an official Logstash image with the plugin installed from source.
- Releases push a tested image per supported Logstash version to `ghcr.io/basht0p/m365-logstash-input-plugin` and list the images in the release notes.
- A re-run release for an existing tag no longer replaces the release's files.
- `Initialize-M365LogstashTenant.ps1` no longer fails with "The property 'appId' cannot be found" when an application or service principal doesn't exist yet in the tenant, so it can go on to create it.
- The tenant helper's `Validate` phase waits for newly consented roles to reach the app-only token instead of failing with HTTP 401 right after consent, and failed API checks include the service's error code and message.
- The `defender_incident` collector requests 50 incidents per page, the most `/security/incidents` allows, instead of failing every run with HTTP 400 ("The limit of '50' for Top query has been exceeded").

## [0.1.0]

First pre-release. It hasn't been validated against a live Microsoft tenant; see [validation status](docs/validation-status.md) before deploying it. Each release carries one offline pack per supported Logstash version (`logstash-input-microsoft365-<version>-logstash-<logstash version>-offline.zip`), the plugin gem, and `SHA256SUMS.txt`. Install the pack that matches your Logstash version with `bin/logstash-plugin install file:///absolute/path/<pack>.zip`.

- Collectors for the Management Activity API, Entra sign-ins (v1.0, and experimental beta), directory audits, Defender alerts and incidents, Identity Protection risk detections and risky users, and Advanced Hunting jobs.
- Commercial, GCC, GCC High, and DoD cloud profiles.
- Certificate or client secret authentication through MSAL.
- Per-tenant checkpoints and dedupe state in a local H2 database, with late-arrival overlap sweeps, reconciliation, `replay_from` re-delivery, and source-gap reporting.
- ECS v8 field mapping, with the source record under `microsoft.raw`.
- `Initialize-M365LogstashTenant.ps1` to provision the tenant application and its permissions.
- Tested in CI on Logstash 8.19.22 and 9.5.4, including installation of the offline packs with networking disabled.
