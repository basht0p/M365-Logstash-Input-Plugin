# Collectors, permissions, and licensing

The plugin uses Microsoft 365 Management Activity API and Microsoft Graph REST APIs. It requests application permissions for app-only authentication. Grant only the permissions required by the collectors you enable. The [tenant helper](provisioning.md) derives its requested permissions from the repository's collector manifest.

| Collector name | Data source | Required application permission |
|---|---|---|
| `activity` | Management Activity API | `ActivityFeed.Read` |
| `signin` | Graph sign-in logs, v1.0 | `AuditLog.Read.All` |
| `signin_beta` | Graph sign-in logs, beta; experimental | `AuditLog.Read.All` |
| `directory_audit` | Graph directory audit logs, v1.0 | `AuditLog.Read.All` |
| `defender_alert` | Graph Defender alerts v2 | `SecurityAlert.Read.All` |
| `defender_incident` | Graph Defender incidents | `SecurityIncident.Read.All` |
| `risk_detection` | Graph Identity Protection risk detections | `IdentityRiskEvent.Read.All` |
| `risky_user` | Graph Identity Protection risky users | `IdentityRiskyUser.Read.All` |
| `hunting` | Graph Advanced Hunting | `ThreatHunting.Read.All` |

`include_dlp => true` enables the `DLP.All` activity content type. `include_sensitive_dlp => true` separately requests `ActivityFeed.ReadDlp` for sensitive DLP details; it requires `include_dlp => true`. Sign-in results can optionally include Conditional Access policy details with `include_conditional_access => true`, which requests `Policy.Read.ConditionalAccess`. These options add scope and are not needed for basic collection. The `signin_beta` collector requires `allow_beta => true` and remains experimental.

Microsoft permission names and API availability can change. Confirm them against the official API documentation and your tenant's admin consent page before rollout. Permission consent alone does not grant product licensing or enable a workload.

## Licensing and tenant prerequisites

Collection depends on the tenant's subscriptions and service configuration. Audit activity feeds require the corresponding Microsoft 365 audit service and supported workload subscriptions. Defender, Identity Protection, and Advanced Hunting APIs require the relevant Defender/Entra products and roles or licensing in the tenant. The plugin cannot enable those products. Empty responses do not prove that an API or license is configured correctly.

Use the helper's validation phase, then verify that expected source events appear in the tenant's own portal and API. Check workload licensing, audit configuration, retention, and source-specific API limits with the tenant administrator. Do not infer that a collector is available in a government cloud merely because its endpoint exists; service and licensing availability must be checked separately.

## Microsoft references

- [Office 365 Management Activity API reference](https://learn.microsoft.com/en-us/office/office-365-management-api/office-365-management-activity-api-reference)
- [List sign-ins](https://learn.microsoft.com/en-us/graph/api/signin-list?view=graph-rest-1.0)
- [List directory audits](https://learn.microsoft.com/en-us/graph/api/directoryaudit-list?view=graph-rest-1.0)
- [List Defender alerts](https://learn.microsoft.com/en-us/graph/api/security-list-alerts_v2?view=graph-rest-1.0)
- [List Defender incidents](https://learn.microsoft.com/en-us/graph/api/security-list-incidents?view=graph-rest-1.0)
- [Run an Advanced Hunting query](https://learn.microsoft.com/en-us/graph/api/security-security-runhuntingquery?view=graph-rest-1.0)
- [List risk detections](https://learn.microsoft.com/en-us/graph/api/riskdetection-list?view=graph-rest-1.0)
- [List risky users](https://learn.microsoft.com/en-us/graph/api/riskyuser-list?view=graph-rest-1.0)
