# Logstash Microsoft 365 input

`logstash-input-microsoft365` collects Microsoft 365 activity and Microsoft Graph security and identity events through REST APIs. Configure one input per tenant; each input has its own application credentials and local checkpoint state.

The repository is under active development. See [implementation and validation status](docs/validation-status.md) before using it in production. Cloud profiles and service availability depend on the tenant's Microsoft licensing, enabled workloads, API access, and cloud environment.

## Documentation

- [Installation and first pipeline](docs/get-started.md)
- [Collectors, permissions, and licensing](docs/collectors-and-permissions.md)
- [Cloud profiles and government cloud validation](docs/clouds.md)
- [Checkpoints, duplicates, and recovery](docs/operations.md)
- [Architecture and release gates](docs/architecture.md)
- [Advanced Hunting jobs](docs/hunting.md)
- [Tenant application provisioning helper](docs/provisioning.md)
- [Deployment examples](examples/)
- [Implementation and validation status](docs/validation-status.md)

## Event Hubs

Native Event Hubs ingestion is outside this plugin. For streaming workloads, use the Logstash [Kafka input](https://www.elastic.co/guide/en/logstash/current/plugins-inputs-kafka.html) with Microsoft Event Hubs' Kafka endpoint. The separate [Azure Event Hubs input](https://www.elastic.co/guide/en/logstash/current/plugins-inputs-azure_event_hubs.html) is another option. See [the companion pipeline](examples/event-hubs-kafka.conf); it is not a component of this input plugin.

## License

See [LICENSE](LICENSE).
