# Tenant app and service principal provisioning

`scripts/Initialize-M365LogstashTenant.ps1` prepares one single-tenant Entra application and its service principal for the Logstash input. It declares only the application permissions for selected collectors, creates missing app-role assignments during consent, and writes a resumable manifest plus Logstash configuration. Review the script's output and use a suitably privileged administrator for the consent phase.

## Requirements

- PowerShell 7.4 or later.
- Microsoft Graph PowerShell modules `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications`.
- A signed-in Graph context for the requested tenant and cloud, or interactive sign-in when prompted.
- App management permissions for provisioning. Granting Microsoft Graph application permissions requires an appropriately privileged administrator (typically Privileged Role Administrator or Global Administrator).

The helper does not grant directory roles to the runtime application, enable products, configure audit policies, or prove licensing. Its permission and connection validation cannot replace an authorized live collector smoke test.

## Preview and provision

Run a local plan to preview requested resources and output without writing to the target tenant:

```powershell
./scripts/Initialize-M365LogstashTenant.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -Cloud commercial `
  -Collectors activity,signin,directory_audit `
  -Phase Plan `
  -WhatIf
```

Provision the application and service principal, then obtain admin consent as a separately authorized step:

```powershell
$pfxPassword = Read-Host -AsSecureString "Set a password for the generated PFX"
./scripts/Initialize-M365LogstashTenant.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -Cloud commercial `
  -DisplayName "Logstash Microsoft 365 Collector" `
  -Collectors activity,signin,directory_audit,defender_alert `
  -OrganizationId "example-org" `
  -OrganizationName "Example Organization" `
  -Phase Provision `
  -GenerateCertificate `
  -CertificatePassword $pfxPassword `
  -OutputDirectory ./m365-onboarding
```

After the application exists, use the generated manifest to resume and grant consent:

```powershell
./scripts/Initialize-M365LogstashTenant.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -Cloud commercial `
  -Collectors activity,signin,directory_audit,defender_alert `
  -Phase Consent `
  -ResumeManifestPath ./m365-onboarding/tenant-manifest.json `
  -OutputDirectory ./m365-onboarding
```

The app can instead be selected explicitly with `-ExistingApplicationId`. Do not choose an existing app by display name alone. Each phase independently derives its permission set from the supplied switches, so repeat the same `-Collectors`, content type, beta, and optional permission flags used in the provisioning phase when you run `Consent` or `Validate`. The phases are `Plan`, `Provision`, `Consent`, `Validate`, and `All` (default). `-WhatIf` only produces a local plan; it does not create app objects or grant consent.

## Credentials and generated files

Certificate authentication is the default. Certificate creation is explicit: `-GenerateCertificate` creates a certificate and PFX in the output directory, optionally protected by `-CertificatePassword` (a `SecureString`). Protect the output directory and transfer the private PFX only to the Logstash host. The public certificate is what is registered on the app. An existing certificate can be supplied with `-CertificatePath`; `-CertificatePfxPath` may be supplied for validation where needed.

Secret authentication is optional. Supply `-Authentication Secret` and a `-ClientSecret` `SecureString` when validating an existing secret-based app. Secret artifacts are sensitive; keep them out of source control and use the generated credential import instructions to place values in the Logstash keystore.

The helper writes `tenant-manifest.json` (resume state), `microsoft365.conf` (tenant-specific input block), `provisioning-report.json`, and `credential-import.txt`. Certificate runs can additionally write `m365-logstash-certificate.cer` and `.pfx`; secret mode can write `m365-logstash-client-secret.txt`. Treat credential-bearing output as a secret even if the helper protects file permissions.

## Collector options

Use `-IncludeDlp` to enable the `DLP.All` Activity content type. Separately use `-IncludeSensitiveDlp` to request the `ActivityFeed.ReadDlp` permission for sensitive DLP details. Use `-IncludeConditionalAccess` to request `Policy.Read.ConditionalAccess`. `-AllowBeta` is required for `signin_beta`; beta collection remains experimental. `-ActivityContentTypes` and `-SigninTypes` narrow requested feeds/categories. For hunting validation, optionally provide `-HuntingValidationQuery`; `-HuntingQueriesPath` can place the job file path in the generated Logstash block. `-PublisherIdentifier` is the publisher/vendor tenant GUID for Activity API requests, not the customer tenant ID.

Provisioning can be resumed from a manifest. `-RotateCredential` explicitly performs credential rotation; review generated artifacts and complete rollover before removing an older credential. See [collector permissions](collectors-and-permissions.md) and [cloud profiles](clouds.md) before consent.
