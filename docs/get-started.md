# Installation and first pipeline

This input is under development. Use the installation method shipped by the current repository build and follow [validation status](validation-status.md) before deploying. The configuration below uses the current plugin contract; confirm it against the version you install.

## Prerequisites

- Logstash 8.19 or a tested Logstash 9.x release. For at-least-once crash recovery, configure a persistent queue with `queue.checkpoint.writes: 1` and keep both the queue and plugin H2 state directory on durable storage.
- A single-tenant Entra application and its service principal in the target tenant.
- Admin consent for the application permissions corresponding to enabled collectors.
- A certificate registered on the app (recommended) or a client secret stored in the Logstash keystore.
- A writable, durable local directory for this tenant's checkpoint database.

Create the app and prepare configuration with the [provisioning helper](provisioning.md). Keep the private key and credentials accessible only to the Logstash service account. Do not put secrets directly in pipeline files.

The persistent queue and durable H2 state are both required for at-least-once recovery. The exact `logstash.yml` settings and the loss boundary with default queue checkpointing are described in [operations and recovery](operations.md).

## Minimal pipeline

This enables the default collectors: `activity`, `signin`, and `directory_audit`.

```logstash
input {
  microsoft365 {
    tenant_id => "00000000-0000-0000-0000-000000000000"
    client_id => "11111111-1111-1111-1111-111111111111"
    cloud => "commercial"
    organization_id => "example-org"
    organization_name => "Example Organization"

    certificate_path => "/etc/logstash/secrets/m365-client.pfx"
    certificate_password => "${M365_CERTIFICATE_PASSWORD}"

    # Keep this directory durable across service restarts. Use a different
    # directory for each input/tenant.
    state_path => "/var/lib/logstash/m365/example-org"
  }
}

output {
  stdout { codec => rubydebug { metadata => true } }
}
```

Set `M365_CERTIFICATE_PASSWORD` from a Logstash keystore entry or an environment secret manager. For password-based authentication, replace the certificate settings with:

```logstash
    client_secret => "${M365_CLIENT_SECRET}"
```

Configure plugin secrets with the Logstash keystore, for example `bin/logstash-keystore --path.settings /etc/logstash create` followed by `bin/logstash-keystore --path.settings /etc/logstash add M365_CERTIFICATE_PASSWORD`. For secret authentication, add `M365_CLIENT_SECRET` instead. See [Logstash keystore documentation](https://www.elastic.co/guide/en/logstash/current/keystore.html).

## Build and install

Building the gem vendors its Java dependencies. From the repository root, install a JDK 21 and Maven 3, make Ruby available, fetch the pinned Java dependencies into `vendor/jar-dependencies`, then build the gem:

```sh
mvn -B dependency:copy-dependencies
gem build logstash-input-microsoft365.gemspec
```

Install the resulting gem into the Logstash distribution you will run:

```sh
bin/logstash-plugin install --no-verify /path/to/logstash-input-microsoft365-0.1.0.gem
```

The repository build and plugin configuration have passed on Logstash 8.19.22 and 9.5.4; see [validation status](validation-status.md). Use `--no-verify` only for an artifact you have built or obtained through your trusted release process.

### Prepare an offline installation pack

On a machine with the target Logstash version and network access, first install the plugin gem as above. Then prepare an offline pack. Use an absolute output path:

```sh
mkdir -p pkg
bin/logstash-plugin prepare-offline-pack \
  --output "$PWD/pkg/logstash-input-microsoft365-0.1.0.zip" \
  logstash-input-microsoft365
```

Copy the pack to a network-isolated host running the matching Logstash version and install it from a file URL:

```sh
bin/logstash-plugin install file:///absolute/path/logstash-input-microsoft365-0.1.0.zip
```

Offline pack creation and installation have been verified in a fresh Logstash 9.5.4 container with networking disabled, and `config.test_and_exit` passed there without a source plugin path. Offline installation has not yet been verified locally on 8.19.22; build and prepare packs separately for each supported Logstash version. See [validation status](validation-status.md).

## Output fields

With `ecs_compatibility => "v8"` (the default), events include `@timestamp`, `event.dataset`, `event.id`, `event.kind`, `event.action`, `event.provider`, and `event.created`. The plugin maps available organization, user, source IP, device, and outcome fields. Tenant identity and the source response are always available as `microsoft.tenant_id` and `microsoft.raw`; `preserve_original` separately controls the canonical JSON string under `event.original`. Every event includes `accounting.log.type: microsoft_365`.

Set `ecs_compatibility => "disabled"` to omit ECS event, organization, user, source, and device mappings. The event still includes `@timestamp`, `microsoft.tenant_id`, `microsoft.raw`, and `accounting.log.type`; the dataset and source ID are written under `microsoft.dataset` and `microsoft.source_id`. With this mode, `preserve_original => true` writes `microsoft.original`.

Two output metadata identifiers are provided. `@metadata.document_id` is stable for a given entity version and is useful for append-only history. `@metadata.entity_id` is stable across versions of the same source entity and is useful for upserting mutable current-state records. Metadata is not indexed in the event body.

`preserve_original` defaults to `false`; `microsoft.raw` is still included. Set it to `true` when you also want the canonical JSON string. The sample output requires the separately installed [Logstash OpenSearch output plugin](https://github.com/opensearch-project/logstash-output-opensearch); the input gem does not install it. Apply the example mapping before indexing, especially the disabled mapping for `microsoft.raw`, to avoid indexing every nested vendor field. See the [OpenSearch examples](../examples/) for append-only history and current-state indexing patterns.
