# Changelog

## [0.1.0]

First pre-release. It hasn't been validated against a live Microsoft tenant; see [validation status](docs/validation-status.md) before deploying it. Each release carries one offline pack per supported Logstash version (`logstash-input-microsoft365-<version>-logstash-<logstash version>-offline.zip`), the plugin gem, and `SHA256SUMS.txt`. Install the pack that matches your Logstash version with `bin/logstash-plugin install file:///absolute/path/<pack>.zip`.

- Collectors for the Management Activity API, Entra sign-ins (v1.0, and experimental beta), directory audits, Defender alerts and incidents, Identity Protection risk detections and risky users, and Advanced Hunting jobs.
- Commercial, GCC, GCC High, and DoD cloud profiles.
- Certificate or client secret authentication through MSAL.
- Per-tenant checkpoints and dedupe state in a local H2 database, with late-arrival overlap sweeps, reconciliation, `replay_from` re-delivery, and source-gap reporting.
- ECS v8 field mapping, with the source record under `microsoft.raw`.
- `Initialize-M365LogstashTenant.ps1` to provision the tenant application and its permissions.
- Tested in CI on Logstash 8.19.22 and 9.5.4, including installation of the offline packs with networking disabled.
