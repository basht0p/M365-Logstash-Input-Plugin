# Advanced Hunting jobs

The `hunting` collector runs named jobs from a JSON file. Advanced Hunting uses the Microsoft Graph v1.0 endpoint and requires `ThreatHunting.Read.All` application permission plus an eligible Defender tenant. Result limits and query execution limits apply; design jobs to return manageable windows.

The file may be a JSON array of jobs or an object with a `jobs` array. Each job requires `name`, `query`, and `mode` (`incremental` or `snapshot`). `interval` is optional (defaults to the input's `hunting_interval`, 300 seconds); `max_rows` is optional (defaults to 100,000 and cannot exceed that value). Incremental jobs also require `timestamp_field` and nonempty `identity_fields`; `initial_lookback` overrides the input's initial lookback for that job. A representative incremental job is:

```json
{
  "jobs": [
    {
      "name": "device-logons",
      "query": "DeviceLogonEvents | where Timestamp >= {{start}} and Timestamp < {{end}} | project Timestamp, DeviceId, DeviceName, AccountName, ActionType",
      "mode": "incremental",
      "interval": 300,
      "timestamp_field": "Timestamp",
      "identity_fields": ["DeviceId", "Timestamp", "AccountName", "ActionType"],
      "initial_lookback": 86400,
      "max_rows": 100000
    }
  ]
}
```

Incremental jobs must include both `{{start}}` and `{{end}}` placeholders and filter the event timestamp to the half-open interval. The plugin replaces each placeholder with a complete KQL `datetime(...)` literal; do not wrap placeholders in another `datetime()` call. Include stable identity columns in `identity_fields` so overlapping retrievals can be deduplicated. Windows are at most one hour; when the response reaches `max_rows` or is too large, the collector splits the window and retries each half. If a result cap persists below the minimum split size, the job fails visibly and its checkpoint does not advance.

A snapshot job reruns a query on the configured interval and should represent a point-in-time result set rather than an event stream:

```json
{
  "jobs": [
    {
      "name": "high-risk-devices",
      "query": "DeviceInfo | where IsInternetFacing == true | project DeviceId, DeviceName, OSPlatform, Timestamp",
      "mode": "snapshot",
      "interval": 3600,
      "timestamp_field": "Timestamp",
      "identity_fields": ["DeviceId"],
      "max_rows": 100000
    }
  ]
}
```

Snapshot results are run-scoped by design: their source identity and both output metadata IDs include the run time. Store them in append-only history if you need to preserve each query result. The current-state `entity_id` upsert example below is intended for mutable Defender and risk records, not hunting snapshots.

Configure the collector and query file in the input:

```logstash
    collectors => ["activity", "signin", "hunting"]
    hunting_queries_path => "/etc/logstash/m365/hunting-jobs.json"
    hunting_interval => 300
```

See Microsoft's [Graph Advanced Hunting API](https://learn.microsoft.com/en-us/graph/api/security-security-runhuntingquery?view=graph-rest-1.0) and [security API overview](https://learn.microsoft.com/en-us/graph/api/resources/security-api-overview?view=graph-rest-1.0). A query rejected for permission, syntax, execution timeout, or result limits should be corrected at its source; repeatedly replaying an oversized window can worsen throttling.
