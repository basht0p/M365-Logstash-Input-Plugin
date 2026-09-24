# Cloud profiles and validation

Select the cloud where the tenant is hosted. The plugin uses separate token audiences for Graph and the Management Activity API. Do not reuse URLs or continuation links across clouds.

| `cloud` | Authority | Microsoft Graph | Activity API |
|---|---|---|---|
| `commercial` | `login.microsoftonline.com` | `graph.microsoft.com` | `manage.office.com` |
| `gcc` | `login.microsoftonline.com` | `graph.microsoft.com` | `manage-gcc.office.com` |
| `gcc_high` | `login.microsoftonline.us` | `graph.microsoft.us` | `manage.office365.us` |
| `dod` | `login.microsoftonline.us` | `dod-graph.microsoft.us` | `manage.protection.apps.mil` |

These profiles describe endpoint selection. They do not establish that every API, workload, or license is available in every cloud. Confirm the specific service in the target tenant before enabling a collector.

The repository currently has endpoint metadata for all four profiles. Government-cloud support must be considered unverified until smoke tests have run against real GCC, GCC High, or DoD tenants. See [validation status](validation-status.md) for current evidence. Microsoft publishes its [Graph national cloud deployments](https://learn.microsoft.com/en-us/graph/deployments) and the [Activity API cloud endpoints](https://learn.microsoft.com/en-us/office/office-365-management-api/office-365-management-activity-api-reference).
