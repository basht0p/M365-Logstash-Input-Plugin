BeforeAll {
    # CI does not need Microsoft.Graph installed: every tenant call is mocked.
    function Get-MgContext { }
    $script:helper = Join-Path $PSScriptRoot '../Initialize-M365LogstashTenant.ps1'
    . $script:helper -TenantId '11111111-1111-1111-1111-111111111111' -Cloud commercial -Phase Provision -OutputDirectory $TestDrive
    $script:shared = Get-SetupManifest
    $script:selection = Get-SetupSelection $script:shared
}

Describe 'Local planning and input validation' {
    It 'prints permissions from the shared manifest without a Graph connection or filesystem output' {
        Mock Assert-SetupContext { throw 'Graph must not be called' }
        $result = & $script:helper -TenantId '11111111-1111-1111-1111-111111111111' -Cloud gcc_high -Phase Plan -Collectors activity,hunting -IncludeDlp -IncludeSensitiveDlp
        $result.application_permissions.activity | Should -Contain 'ActivityFeed.ReadDlp'
        $result.application_permissions.graph | Should -Contain 'ThreatHunting.Read.All'
        $result.graph_environment | Should -Be 'USGov'
        Should -Invoke Assert-SetupContext -Times 0
    }

    It 'treats WhatIf as an offline read-only plan' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $result = & $script:helper -TenantId '11111111-1111-1111-1111-111111111111' -Cloud commercial -Phase All -WhatIf -OutputDirectory $folder
        $result.application_permissions.graph | Should -Contain 'AuditLog.Read.All'
        Test-Path $folder | Should -BeFalse
    }

    It 'requires explicit beta and sensitive DLP opt-in' {
        { & $script:helper -TenantId '11111111-1111-1111-1111-111111111111' -Cloud commercial -Phase Plan -Collectors signin_beta } | Should -Throw '*AllowBeta*'
        { & $script:helper -TenantId '11111111-1111-1111-1111-111111111111' -Cloud commercial -Phase Plan -ActivityContentTypes DLP.All } | Should -Throw '*IncludeDlp*'
    }
}

Describe 'Resource and permission safety' {
    BeforeEach { $script:requests = @() }

    It 'merges required access and preserves unrelated roles' {
        $app = @{ id = 'client-object'; requiredResourceAccess = @(@{ resourceAppId = 'other-resource'; resourceAccess = @(@{ id = 'other-role'; type = 'Role' }) }) }
        $resources = @{ graph = @{ roles = @{ 'AuditLog.Read.All' = 'audit-role' } } }
        Mock Invoke-SetupGraph {
            param($Method,$Path,$Body,$Manifest)
            $script:requests += @{ method = $Method; path = $Path; body = $Body }
        }
        Merge-SetupRequiredAccess $app $resources $script:shared | Should -BeTrue
        $script:requests.Count | Should -Be 1
        $script:requests[0].body.requiredResourceAccess.Count | Should -Be 2
        ($script:requests[0].body.requiredResourceAccess | Where-Object resourceAppId -eq 'other-resource').resourceAccess[0].id | Should -Be 'other-role'
        ($script:requests[0].body.requiredResourceAccess | Where-Object resourceAppId -eq $script:shared.resources.graph.app_id).resourceAccess[0].id | Should -Be 'audit-role'
    }

    It 'does not duplicate an existing required role' {
        $app = @{ id = 'client-object'; requiredResourceAccess = @(@{ resourceAppId = $script:shared.resources.graph.app_id; resourceAccess = @(@{ id = 'audit-role'; type = 'Role' }) }) }
        $resources = @{ graph = @{ roles = @{ 'AuditLog.Read.All' = 'audit-role' } } }
        Mock Invoke-SetupGraph { throw 'must not mutate' }
        Merge-SetupRequiredAccess $app $resources $script:shared | Should -BeFalse
        Should -Invoke Invoke-SetupGraph -Times 0
    }

    It 'does not duplicate existing consent assignments' {
        $resources = @{ graph = @{ sp = @{ id = 'graph-object' }; roles = @{ 'AuditLog.Read.All' = 'audit-role'; 'SecurityAlert.Read.All' = 'alert-role' } } }
        Mock Get-SetupGraphPages { return @(@{ resourceId = 'graph-object'; appRoleId = 'audit-role' }) }
        Mock Invoke-SetupGraph {
            param($Method,$Path,$Body,$Manifest)
            $script:requests += @{ method = $Method; path = $Path; body = $Body }
        }
        $added = @(Grant-SetupRoles @{ id = 'client-object' } $resources $script:shared)
        $added | Should -Be @('graph/SecurityAlert.Read.All')
        $script:requests.Count | Should -Be 1
        $script:requests[0].body.principalId | Should -Be 'client-object'
        $script:requests[0].body.resourceId | Should -Be 'graph-object'
    }

    It 'rejects a resource principal that does not advertise the cloud audience' {
        Mock Get-SetupSp { return @{ id='graph-object'; appId='00000003-0000-0000-c000-000000000000'; servicePrincipalNames=@('00000003-0000-0000-c000-000000000000','https://graph.microsoft.us'); appRoles=@() } }
        { Get-SetupResources $script:shared $script:selection } | Should -Throw '*does not advertise https://graph.microsoft.com*'
    }

    It 'reads a single application to preserve existing certificate bytes' {
        Mock Get-SetupGraphPages { return @(@{ id='client-object'; appId='11111111-1111-1111-1111-111111111111'; keyCredentials=@(@{ key=$null }) }) }
        Mock Invoke-SetupGraph { return @{ id='client-object'; appId='11111111-1111-1111-1111-111111111111'; keyCredentials=@(@{ key='public-cert-bytes' }) } }
        $app = Get-SetupApp '11111111-1111-1111-1111-111111111111' $script:shared
        $app.keyCredentials[0].key | Should -Be 'public-cert-bytes'
        Should -Invoke Invoke-SetupGraph -Times 1 -ParameterFilter { $Method -eq 'GET' -and $Path -like '/applications/client-object*' }
    }

    It 'fails before mutation when a Graph context belongs to another tenant' {
        Mock Import-Module { }
        Mock Get-MgContext { return @{ TenantId='33333333-3333-3333-3333-333333333333'; Environment='Global'; Scopes=@('Application.ReadWrite.All') } }
        { Assert-SetupContext $script:shared } | Should -Throw '*tenant/environment mismatch*'
    }

    It 'accepts Application.ReadWrite.All for a split Consent operator' {
        . $script:helper -TenantId '11111111-1111-1111-1111-111111111111' -Cloud commercial -Phase Consent
        Mock Import-Module { }
        Mock Get-MgContext { return @{ TenantId='11111111-1111-1111-1111-111111111111'; Environment='Global'; Scopes=@('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All') } }
        { Assert-SetupContext $script:shared } | Should -Not -Throw
    }
}

Describe 'Certificate and secret handling' {
    It 'creates a password encrypted PFX and public certificate with a one-year bound' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        [void](New-Item -ItemType Directory -Path $folder)
        $password = ConvertTo-SecureString 'test-password' -AsPlainText -Force
        $created = New-SetupCertificate $folder $password
        Test-Path $created.pfx_path | Should -BeTrue
        Test-Path $created.certificate_path | Should -BeTrue
        if (-not $IsWindows) {
            [IO.File]::GetUnixFileMode($folder).ToString() | Should -Be 'UserExecute, UserWrite, UserRead'
            [IO.File]::GetUnixFileMode($created.pfx_path).ToString() | Should -Be 'UserWrite, UserRead'
        }
        { [Security.Cryptography.X509Certificates.X509Certificate2]::new($created.pfx_path, 'wrong-password') } | Should -Throw
        $cert = Get-SetupCertificate $created.certificate_path
        try {
            $cert.PublicKey.Oid.FriendlyName | Should -Be 'RSA'
            $cert.NotAfter.ToUniversalTime() | Should -BeGreaterThan ([datetime]::UtcNow.AddDays(300))
        } finally { $cert.Dispose() }
    }

    It 'keeps existing certificate keys during explicit rotation' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        [void](New-Item -ItemType Directory -Path $folder)
        $created = New-SetupCertificate $folder (ConvertTo-SecureString 'test-password' -AsPlainText -Force)
        $app = @{ id='client-object'; keyCredentials=@(@{ customKeyIdentifier='old-key'; key='old-data'; type='AsymmetricX509Cert'; usage='Verify' }) }
        Mock Invoke-SetupGraph {
            param($Method,$Path,$Body,$Manifest)
            $script:capturedKeys = $Body.keyCredentials
        }
        Set-SetupCertificateCredential $app $created.certificate_path $script:shared $true | Should -BeTrue
        $script:capturedKeys.Count | Should -Be 2
        $script:capturedKeys[0].customKeyIdentifier | Should -Be 'old-key'
        $script:capturedKeys[0].key | Should -Be 'old-data'
    }

    It 'refuses to replace keys when Graph returned redacted key material' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        [void](New-Item -ItemType Directory -Path $folder)
        $created = New-SetupCertificate $folder (ConvertTo-SecureString 'test-password' -AsPlainText -Force)
        $app = @{ id='client-object'; keyCredentials=@(@{ customKeyIdentifier='old-key'; key=$null }) }
        Mock Invoke-SetupGraph { throw 'must not patch' }
        { Set-SetupCertificateCredential $app $created.certificate_path $script:shared $true } | Should -Throw '*key material is unavailable*'
        Should -Invoke Invoke-SetupGraph -Times 0
    }
}

Describe 'Recovery and app-only validation' {
    It 'records the newly created app before a service principal failure and adopts it on retry' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        . $script:helper -TenantId '11111111-1111-1111-1111-111111111111' -Cloud commercial -Phase Provision -Authentication Secret -Collectors signin -OutputDirectory $folder
        $script:appExists = $false
        $script:spFails = $true
        $script:appPosts = 0
        Mock Assert-SetupContext { }
        Mock Get-SetupResources { return @{ graph = @{ sp=@{ id='graph-object' }; roles=@{ 'AuditLog.Read.All'='audit-role' } } } }
        Mock Get-SetupApp {
            if ($script:appExists) { return @{ id='client-object'; appId='22222222-2222-2222-2222-222222222222'; signInAudience='AzureADMyOrg'; requiredResourceAccess=@(); keyCredentials=@(); passwordCredentials=@() } }
            return $null
        }
        Mock Get-SetupSp { return $null }
        Mock Invoke-SetupGraph {
            param($Method,$Path,$Body,$Manifest)
            if ($Path -eq '/applications') {
                $script:appPosts++
                $script:appExists = $true
                return @{ id='client-object'; appId='22222222-2222-2222-2222-222222222222'; signInAudience='AzureADMyOrg'; requiredResourceAccess=@(); keyCredentials=@(); passwordCredentials=@() }
            }
            if ($Path -eq '/servicePrincipals') {
                if ($script:spFails) { throw 'simulated SP creation failure' }
                return @{ id='client-sp'; appId='22222222-2222-2222-2222-222222222222' }
            }
            if ($Path -like '*/addPassword') { return @{ secretText='one-time-test-secret' } }
            return @{}
        }
        { Invoke-SetupMain } | Should -Throw '*simulated SP creation failure*'
        (Get-Content (Join-Path $folder 'tenant-manifest.json') -Raw | ConvertFrom-Json).application_id | Should -Be '22222222-2222-2222-2222-222222222222'
        $script:spFails = $false
        $result = Invoke-SetupMain
        $result.application_id | Should -Be '22222222-2222-2222-2222-222222222222'
        $script:appPosts | Should -Be 1
        (Get-Content (Join-Path $folder 'microsoft365.conf') -Raw) | Should -Not -Match 'one-time-test-secret'
        Test-Path (Join-Path $folder 'm365-logstash-client-secret.txt') | Should -BeTrue
    }

    It 'signs a certificate assertion and requests an Activity resource token' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        [void](New-Item -ItemType Directory -Path $folder)
        $password = ConvertTo-SecureString 'test-password' -AsPlainText -Force
        $created = New-SetupCertificate $folder $password
        Mock Invoke-RestMethod {
            param($Method,$Uri,$Body)
            $script:capturedTokenBody = $Body
            return @{ access_token = 'fake-token' }
        }
        $token = Get-SetupAppToken '22222222-2222-2222-2222-222222222222' 'https://manage.office.com' $script:shared $null $created.pfx_path $password
        $token | Should -Be 'fake-token'
        $script:capturedTokenBody.scope | Should -Be 'https://manage.office.com/.default'
        $parts = $script:capturedTokenBody.client_assertion.Split('.')
        $parts.Count | Should -Be 3
        $encoded = $parts[2].Replace('-','+').Replace('_','/')
        $encoded = $encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '=')
        $signature = [Convert]::FromBase64String($encoded)
        $publicCert = Get-SetupCertificate $created.certificate_path
        try {
            $publicKey = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($publicCert)
            try {
                $publicKey.VerifyData([Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"), $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) | Should -BeTrue
            } finally { $publicKey.Dispose() }
        } finally { $publicCert.Dispose() }
    }

    It 'leaves an existing Activity subscription and webhook untouched' {
        $script:activityCalls = @()
        $chosen = @{ collectors=@('activity'); permissions=@{ graph=[Collections.Generic.HashSet[string]]::new(); activity=[Collections.Generic.HashSet[string]]::new() }; activity_content_types=@('Audit.Exchange') }
        [void]$chosen.permissions.activity.Add('ActivityFeed.Read')
        Mock Get-SetupAppToken { return 'fake-token' }
        Mock Invoke-SetupProbe {
            param($Method,$Uri,$Token,$Body)
            $script:activityCalls += "$Method $Uri"
            return @(@{ contentType='Audit.Exchange'; status='enabled'; webhook=@{ address='https://existing.example/webhook' } })
        }
        $result = Test-SetupAccess '22222222-2222-2222-2222-222222222222' $script:shared $chosen $null $null $null
        $result['activity/Audit.Exchange'] | Should -Be 'enabled'
        $script:activityCalls.Count | Should -Be 1
        $script:activityCalls[0] | Should -Match '^GET '
    }

    It 'validates a Graph-only collector without requesting Activity access' {
        $chosen = @{ collectors=@('signin'); permissions=@{ graph=[Collections.Generic.HashSet[string]]::new(); activity=[Collections.Generic.HashSet[string]]::new() }; activity_content_types=@() }
        [void]$chosen.permissions.graph.Add('AuditLog.Read.All')
        Mock Get-SetupAppToken { return 'fake-token' }
        Mock Invoke-SetupProbe { return @{ value=@() } }
        $result = Test-SetupAccess '22222222-2222-2222-2222-222222222222' $script:shared $chosen $null $null $null
        $result.signin | Should -Be 'authorized; no records returned'
        Should -Invoke Get-SetupAppToken -Times 1 -ParameterFilter { $Audience -eq 'https://graph.microsoft.com' }
    }
}
