# Changelog

## [Unreleased]

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
