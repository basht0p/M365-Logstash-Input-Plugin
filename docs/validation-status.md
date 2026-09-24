# Implementation and validation status

This page records evidence for the current repository revision. It distinguishes automated checks from live Microsoft tenant validation.

## Supported target (planned)

The implementation targets Logstash 8.19 and 9.x, Microsoft 365 Management Activity API, and Microsoft Graph REST APIs. Graph beta sign-in collection is experimental and must be explicitly enabled. Cloud profiles are present for Commercial, GCC, GCC High, and DoD.

## Evidence

| Area | Evidence/status |
|---|---|
| Logstash pipeline configuration | `config.test_and_exit` passed on official Logstash 8.19.22 and 9.5.4 Docker images. This validates configuration loading on these versions, not long-running API collection. |
| Plugin Ruby specs | RSpec: 16/16 passed on both Logstash 8.19.22 and 9.5.4. |
| Tenant helper tests | Pester: 17/17 passed on Windows and Linux with PowerShell 7.4; helper runtime assertions passed on both. Live provisioning against Microsoft Graph remains pending. |
| Gem packaging | Gem build and installation passed on Logstash 8.19.22 and 9.5.4. Offline pack creation and installation passed in a fresh Logstash 9.5.4 container with networking disabled; `config.test_and_exit` passed without a source plugin path. Local offline installation on 8.19.22 is not yet verified. |
| Container/runtime availability | Official Logstash 8.19.22 and 9.5.4 images were used. The 9.5.4 image reports JRuby 10.0.6, Ruby 3.4.5, and JDK 21.0.12. |
| Runtime harness | Passed on Logstash 8.19.22 and 9.5.4: Base/Event integration, H2 state locking/reopen, backpressure checkpoint delay, MSAL secret/PFX construction, mutable version IDs, and clean shutdown. HTTP was faked; no Microsoft tenant calls were made. |
| Full-queue shutdown stress | In progress. |
| Commercial tenant smoke test | Not yet reported. |
| GCC tenant smoke test | Not yet reported. |
| GCC High tenant smoke test | Not yet reported. |
| DoD tenant smoke test | Not yet reported. |
| 48-hour controlled restart/throttling pilot | Not yet reported. |
| Long-running Logstash 8.19 compatibility | Runtime harness passed on 8.19.22. Live API collection remains unverified. |
| Long-running Logstash 9.x compatibility | Runtime harness passed on 9.5.4. Live API collection remains unverified. |

No Microsoft tenant credentials were used and no live cloud smoke tests have been run. The local runtime and helper tests used simulated HTTP/API calls.

CI builds and tests matching-version offline archives on both Logstash versions. The 8.19.22 offline path has not yet been verified locally.

Endpoint constants or passing mocked tests do not establish live government-cloud service support. Do not describe an environment as verified until an authorized tenant smoke test has succeeded for the enabled sources.

## Production suitability

Treat this as a development release until the evidence above is updated with actual run results. Before production deployment, validate the target tenant's application consent, licensing, audit configuration, source retention, persistent queue behavior, backup/restore process, and expected event fields. Record the exact plugin version and cloud tested.
