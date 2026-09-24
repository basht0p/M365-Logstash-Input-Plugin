#requires -Version 7.4
<#
.SYNOPSIS
Creates one tenant-owned application and service principal for the microsoft365 Logstash input.
.DESCRIPTION
Plan and -WhatIf perform local planning only. Provision creates or resumes an application,
service principal, permissions and a certificate (or a protected one-time secret). Consent
assigns application roles; Validate tests app-only access and starts missing Activity feeds.
No tenant-wide audit or licensing settings are changed.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TenantId,
    [Parameter(Mandatory)][ValidateSet('commercial','gcc','gcc_high','dod')][string]$Cloud,
    [string]$DisplayName = 'Logstash Microsoft 365 Input',
    [string[]]$Collectors = @('activity','signin','directory_audit'),
    [string]$OrganizationId,
    [string]$OrganizationName,
    [ValidateSet('Certificate','Secret')][string]$Authentication = 'Certificate',
    [string]$CertificatePath,
    [string]$CertificatePfxPath,
    [SecureString]$CertificatePassword,
    [switch]$GenerateCertificate,
    [switch]$RotateCredential,
    [ValidateRange(1,1095)][int]$CredentialLifetimeDays = 365,
    [SecureString]$ClientSecret,
    [string]$ExistingApplicationId,
    [string]$ResumeManifestPath,
    [string]$OutputDirectory = (Join-Path (Get-Location) 'm365-tenant-output'),
    [ValidateSet('Plan','Provision','Consent','Validate','All')][string]$Phase = 'All',
    [switch]$IncludeDlp,
    [switch]$IncludeSensitiveDlp,
    [switch]$IncludeConditionalAccess,
    [switch]$AllowBeta,
    [string[]]$ActivityContentTypes = @('Audit.Exchange','Audit.SharePoint','Audit.General'),
    [string[]]$SigninTypes = @('interactiveUser','nonInteractiveUser','servicePrincipal','managedIdentity'),
    [string]$HuntingQueriesPath,
    [string]$HuntingValidationQuery = 'DeviceEvents | take 1',
    [string]$PublisherIdentifier
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SetupData($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) { return $Value }
    return ($Value | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable)
}

function Get-SetupManifest {
    $path = Join-Path $PSScriptRoot '../data/collector_manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Shared collector manifest is missing: $path" }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.schema_version -ne 1) { throw 'Unsupported collector manifest schema.' }
    return $manifest
}

function Get-SetupSelection($Manifest) {
    $selected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $Collectors) {
        if (-not $Manifest.collectors.ContainsKey($name)) { throw "Unknown collector '$name'." }
        if ($Manifest.collectors[$name].experimental -and -not $AllowBeta) {
            throw "Collector '$name' requires -AllowBeta."
        }
        [void]$selected.Add($name)
    }
    if ($selected.Count -eq 0) { throw 'Choose at least one collector.' }
    if (($IncludeDlp -or $IncludeSensitiveDlp) -and -not $selected.Contains('activity')) { throw 'DLP options require the activity collector.' }
    if ($IncludeSensitiveDlp -and -not $IncludeDlp) { throw '-IncludeSensitiveDlp requires -IncludeDlp.' }
    if ($IncludeConditionalAccess -and -not ($selected.Contains('signin') -or $selected.Contains('signin_beta'))) {
        throw '-IncludeConditionalAccess requires a sign-in collector.'
    }
    if ($PublisherIdentifier -and $PublisherIdentifier -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'PublisherIdentifier must be the vendor/developer tenant GUID.'
    }
    $validTypes = @('Audit.Exchange','Audit.SharePoint','Audit.General','Audit.AzureActiveDirectory','DLP.All')
    $selectedContentTypes = @($ActivityContentTypes)
    if ($IncludeDlp -and 'DLP.All' -notin $selectedContentTypes) { $selectedContentTypes += 'DLP.All' }
    foreach ($type in $selectedContentTypes) {
        if ($type -cnotin $validTypes) { throw "Unknown Activity content type '$type'." }
        if ($type -eq 'DLP.All' -and -not $IncludeDlp) { throw 'DLP.All requires -IncludeDlp.' }
    }
    $permissions = @{ graph = [System.Collections.Generic.HashSet[string]]::new(); activity = [System.Collections.Generic.HashSet[string]]::new() }
    foreach ($name in $selected) {
        $entry = $Manifest.collectors[$name]
        foreach ($permission in $entry.permissions) { [void]$permissions[$entry.resource].Add($permission) }
        if ($name -eq 'activity' -and $IncludeSensitiveDlp) { [void]$permissions.activity.Add('ActivityFeed.ReadDlp') }
        if ($name -in @('signin','signin_beta') -and $IncludeConditionalAccess) {
            [void]$permissions.graph.Add('Policy.Read.ConditionalAccess')
        }
    }
    $validSignins = @('interactiveUser','nonInteractiveUser','servicePrincipal','managedIdentity')
    foreach ($type in $SigninTypes) { if ($type -cnotin $validSignins) { throw "Unknown sign-in type '$type'." } }
    return @{ collectors = @($selected | Sort-Object); permissions = $permissions; activity_content_types = $selectedContentTypes }
}

function Get-SetupPlan($Manifest, $Selection) {
    return [ordered]@{
        tenant_id = $TenantId; cloud = $Cloud; graph_environment = $Manifest.clouds[$Cloud].graph_environment
        collectors = $Selection.collectors
        application_permissions = [ordered]@{
            graph = @($Selection.permissions.graph | Sort-Object)
            activity = @($Selection.permissions.activity | Sort-Object)
        }
        authentication = $Authentication; phase = $Phase
        prerequisites = @('PowerShell 7.4+', 'Microsoft.Graph.Authentication and Microsoft.Graph.Applications modules',
            'Application.ReadWrite.All for provisioning', 'AppRoleAssignment.ReadWrite.All and Privileged Role Administrator or Global Administrator for Graph consent',
            'Microsoft 365 audit and workload licenses enabled separately',
            'A hunting queries JSON path when the hunting collector is selected')
        note = 'Activity PublisherIdentifier is the developer/vendor tenant ID. It is never inferred from the customer tenant.'
    }
}

function Assert-SetupContext($Manifest) {
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Applications -ErrorAction Stop
    $expected = $Manifest.clouds[$Cloud].graph_environment
    $context = Get-MgContext
    if (-not $context) {
        $scopes = switch ($Phase) {
            'Provision' { @('Application.ReadWrite.All') }
            'Consent' { @('Application.Read.All','AppRoleAssignment.ReadWrite.All') }
            'Validate' { @('Application.Read.All') }
            default { @('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All') }
        }
        Connect-MgGraph -TenantId $TenantId -Environment $expected -Scopes $scopes -ContextScope Process -NoWelcome | Out-Null
        $context = Get-MgContext
    }
    if (-not $context -or $context.TenantId -ne $TenantId -or $context.Environment -ne $expected) {
        throw "Graph context tenant/environment mismatch. Expected $TenantId / $expected."
    }
    $needed = switch ($Phase) {
        'Provision' { @('Application.ReadWrite.All') }
        'Consent' { @('Application.Read.All','AppRoleAssignment.ReadWrite.All') }
        'Validate' { @('Application.Read.All') }
        default { @('Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All') }
    }
    foreach ($scope in $needed) {
        $granted = @($context.Scopes)
        if ($granted -notcontains $scope -and -not ($scope -eq 'Application.Read.All' -and $granted -contains 'Application.ReadWrite.All')) {
            throw "Current Graph session lacks $scope. Reconnect with the required delegated scope."
        }
    }
}

function Invoke-SetupGraph($Method, $Path, $Body, $Manifest) {
    $base = $Manifest.clouds[$Cloud].graph_base_url
    $uri = if ($Path -match '^https://') { $Path } else { "$base/v1.0$Path" }
    if (([uri]$uri).Scheme -ne 'https' -or ([uri]$uri).Host -ne ([uri]$base).Host) {
        throw 'Rejected cross-cloud Graph URL.'
    }
    $args = @{ Method = $Method; Uri = $uri; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $args.Body = ($Body | ConvertTo-Json -Depth 40 -Compress)
        $args.ContentType = 'application/json'
    }
    return ConvertTo-SetupData (Invoke-MgGraphRequest @args)
}

function Get-SetupGraphPages($Path, $Manifest) {
    $all = [System.Collections.Generic.List[object]]::new()
    $next = $Path
    while ($next) {
        $page = Invoke-SetupGraph GET $next $null $Manifest
        foreach ($item in @($page.value)) { if ($null -ne $item) { $all.Add($item) } }
        $next = $page['@odata.nextLink']
    }
    return @($all)
}

function Get-SetupUniqueByAppId($Collection, $AppId, $Kind) {
    $matches = @($Collection | Where-Object { $_.appId -eq $AppId })
    if ($matches.Count -gt 1) { throw "Multiple $Kind objects have appId $AppId." }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-SetupApp($AppId, $Manifest) {
    $path = '/applications?$filter=' + [uri]::EscapeDataString("appId eq '$AppId'") + '&$select=id,appId'
    $listed = Get-SetupUniqueByAppId (Get-SetupGraphPages $path $Manifest) $AppId 'application'
    if (-not $listed) { return $null }
    # Graph redacts keyCredential.key in list responses, even with $select.
    $detail = Invoke-SetupGraph GET "/applications/$($listed.id)?`$select=id,appId,displayName,signInAudience,requiredResourceAccess,keyCredentials,passwordCredentials" $null $Manifest
    if ($detail.appId -ne $AppId) { throw 'Application detail app ID does not match the requested application.' }
    return $detail
}

function Get-SetupSp($AppId, $Manifest) {
    $path = '/servicePrincipals?$filter=' + [uri]::EscapeDataString("appId eq '$AppId'") + '&$select=id,appId,displayName,servicePrincipalNames,appRoles'
    return Get-SetupUniqueByAppId (Get-SetupGraphPages $path $Manifest) $AppId 'service principal'
}

function Get-SetupResources($Manifest, $Selection, [bool]$AllowCreate = $false) {
    $out = @{}
    foreach ($resource in @('graph','activity')) {
        if ($Selection.permissions[$resource].Count -eq 0) { continue }
        $appId = $Manifest.resources[$resource].app_id
        $sp = Get-SetupSp $appId $Manifest
        if (-not $sp -and $AllowCreate) {
            Invoke-SetupGraph POST '/servicePrincipals' @{ appId = $appId } $Manifest | Out-Null
            for ($attempt = 1; $attempt -le 3 -and -not $sp; $attempt++) {
                $sp = Get-SetupSp $appId $Manifest
                if (-not $sp -and $attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
            }
        }
        if (-not $sp) { throw "Microsoft $resource resource service principal $appId is unavailable in this tenant/cloud." }
        if (@($sp.servicePrincipalNames) -notcontains $appId) {
            throw "Microsoft $resource resource service principal does not advertise its expected app ID."
        }
        $audience = if ($resource -eq 'graph') { $Manifest.clouds[$Cloud].graph_base_url } else { $Manifest.clouds[$Cloud].activity_base_url }
        if (@($sp.servicePrincipalNames) -notcontains $audience) {
            throw "Microsoft $resource resource service principal does not advertise $audience for cloud $Cloud."
        }
        $roles = @{}
        foreach ($permission in $Selection.permissions[$resource]) {
            $matches = @($sp.appRoles | Where-Object { $_.value -eq $permission -and $_.isEnabled -eq $true -and @($_.allowedMemberTypes) -contains 'Application' })
            if ($matches.Count -ne 1) { throw "Microsoft $resource application role '$permission' is unavailable or ambiguous in $Cloud." }
            $roles[$permission] = $matches[0].id
        }
        $out[$resource] = @{ sp = $sp; roles = $roles }
    }
    return $out
}

function Merge-SetupRequiredAccess($App, $Resources, $Manifest) {
    $existing = @($App['requiredResourceAccess'] | Where-Object { $null -ne $_ })
    $changed = $false
    foreach ($resource in $Resources.Keys) {
        $appId = $Manifest.resources[$resource].app_id
        $entry = @($existing | Where-Object { $_.resourceAppId -eq $appId })
        if ($entry.Count -gt 1) { throw "Duplicate requiredResourceAccess entries for $resource." }
        if ($entry.Count -eq 0) {
            $entry = @{ resourceAppId = $appId; resourceAccess = @() }
            $existing += $entry
            $changed = $true
        } else { $entry = $entry[0] }
        $access = @($entry.resourceAccess | Where-Object { $null -ne $_ })
        foreach ($id in $Resources[$resource].roles.Values) {
            if (@($access | Where-Object { $_.id -eq $id -and $_.type -eq 'Role' }).Count -eq 0) {
                $access += @{ id = $id; type = 'Role' }
                $changed = $true
            }
        }
        $entry.resourceAccess = $access
    }
    if ($changed) {
        Invoke-SetupGraph PATCH "/applications/$($App.id)" @{ requiredResourceAccess = $existing } $Manifest | Out-Null
    }
    return $changed
}

function ConvertFrom-SetupSecureString([SecureString]$Value) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Set-SetupPrivateFile($Path, [byte[]]$Bytes) {
    if (Test-Path -LiteralPath $Path) { throw "Refusing to overwrite credential file $Path. Use -RotateCredential with a new output directory." }
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    Assert-SetupPrivateDirectory $parent
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Assert-SetupPrivateDirectory($Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full)) { [void][IO.Directory]::CreateDirectory($full) }
    $item = Get-Item -LiteralPath $full -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Credential output directory must be a real directory, not a link.'
    }
    if ($IsWindows) {
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($full), $acl)
    } else {
        [IO.File]::SetUnixFileMode($full, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
}

function New-SetupCertificate($OutputPath, [SecureString]$Password) {
    if (-not $Password) { throw 'Generating a certificate requires -CertificatePassword (SecureString).' }
    $rsa = [Security.Cryptography.RSA]::Create(3072)
    try {
        $subject = [Security.Cryptography.X509Certificates.X500DistinguishedName]::new('CN=Logstash Microsoft 365 Input')
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new($subject, $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))
        $request.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new([Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature, $true))
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-5), [DateTimeOffset]::UtcNow.AddDays($CredentialLifetimeDays))
        try {
            $pfxPath = Join-Path $OutputPath 'm365-logstash-certificate.pfx'
            $cerPath = Join-Path $OutputPath 'm365-logstash-certificate.cer'
            if ((Test-Path -LiteralPath $pfxPath) -or (Test-Path -LiteralPath $cerPath)) { throw 'Generated certificate files already exist. Resume with -CertificatePath or choose a new output directory.' }
            $plaintext = ConvertFrom-SetupSecureString $Password
            try { $pfx = $certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $plaintext) }
            finally { $plaintext = $null }
            Set-SetupPrivateFile $pfxPath $pfx
            Set-SetupPrivateFile $cerPath ($certificate.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
            return @{ certificate_path = $cerPath; pfx_path = $pfxPath }
        } finally { $certificate.Dispose() }
    } finally { $rsa.Dispose() }
}

function Get-SetupCertificate($Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Certificate file missing: $Path" }
    if ([IO.Path]::GetExtension($Path) -eq '.pem') {
        return [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($Path)
    }
    return [Security.Cryptography.X509Certificates.X509Certificate2]::new($Path)
}

function Set-SetupCertificateCredential($App, $Path, $Manifest, [bool]$Rotate = $false) {
    $certificate = Get-SetupCertificate $Path
    try {
        if ($certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) { throw 'Certificate has expired.' }
        $thumbprint = [Convert]::ToBase64String($certificate.GetCertHash())
        $keys = @($App['keyCredentials'] | Where-Object { $null -ne $_ })
        if (@($keys | Where-Object { -not $_.key }).Count -gt 0) {
            throw 'Existing certificate key material is unavailable; refusing to replace keyCredentials.'
        }
        if (@($keys | Where-Object { $_.customKeyIdentifier -eq $thumbprint }).Count -gt 0) { return $false }
        if ($keys.Count -gt 0 -and -not $Rotate) { throw 'Application has a different certificate. Use -RotateCredential to add this one while retaining the previous key.' }
        $keys += @{
            type = 'AsymmetricX509Cert'; usage = 'Verify'; displayName = 'Logstash Microsoft 365 Input'
            key = [Convert]::ToBase64String($certificate.RawData)
            customKeyIdentifier = $thumbprint
            startDateTime = $certificate.NotBefore.ToUniversalTime().ToString('o')
            endDateTime = $certificate.NotAfter.ToUniversalTime().ToString('o')
        }
        Invoke-SetupGraph PATCH "/applications/$($App.id)" @{ keyCredentials = $keys } $Manifest | Out-Null
        return $true
    } finally { $certificate.Dispose() }
}

function Set-SetupSecretCredential($App, $Manifest, $OutputPath, [bool]$Rotate = $false) {
    if (@($App['passwordCredentials'] | Where-Object { $null -ne $_ }).Count -gt 0 -and -not $Rotate) { return $null }
    $file = Join-Path $OutputPath 'm365-logstash-client-secret.txt'
    if (Test-Path -LiteralPath $file) { throw "Credential file already exists: $file. Choose a new output directory for rotation." }
    $expiry = [DateTime]::UtcNow.AddDays($CredentialLifetimeDays).ToString('o')
    $body = @{ passwordCredential = @{ displayName = 'Logstash Microsoft 365 Input'; endDateTime = $expiry } }
    $result = Invoke-SetupGraph POST "/applications/$($App.id)/addPassword" $body $Manifest
    if (-not $result.secretText) { throw 'Graph did not return the one-time secret. Rotate the credential explicitly to recover.' }
    Set-SetupPrivateFile $file ([Text.Encoding]::UTF8.GetBytes($result.secretText))
    return @{ file = $file; value = (ConvertTo-SecureString $result.secretText -AsPlainText -Force); expires_utc = $expiry }
}

function Grant-SetupRoles($ClientSp, $Resources, $Manifest) {
    $assignments = @(Get-SetupGraphPages "/servicePrincipals/$($ClientSp.id)/appRoleAssignments?`$top=999" $Manifest)
    $added = @()
    foreach ($resource in $Resources.Keys) {
        $resourceSp = $Resources[$resource].sp
        foreach ($permission in $Resources[$resource].roles.Keys) {
            $roleId = $Resources[$resource].roles[$permission]
            if (@($assignments | Where-Object { $_.resourceId -eq $resourceSp.id -and $_.appRoleId -eq $roleId }).Count -gt 0) { continue }
            $body = @{ principalId = $ClientSp.id; resourceId = $resourceSp.id; appRoleId = $roleId }
            Invoke-SetupGraph POST "/servicePrincipals/$($ClientSp.id)/appRoleAssignments" $body $Manifest | Out-Null
            $added += "$resource/$permission"
        }
    }
    return $added
}

function ConvertTo-SetupBase64Url([byte[]]$Bytes) { return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_') }

function Get-SetupAppToken($AppId, $Audience, $Manifest, [SecureString]$Secret, $PfxPath, [SecureString]$PfxPassword) {
    $authority = $Manifest.clouds[$Cloud].authority_host
    $tokenUri = "https://$authority/$TenantId/oauth2/v2.0/token"
    $body = @{ client_id = $AppId; scope = "$Audience/.default"; grant_type = 'client_credentials' }
    if ($Secret) {
        $body.client_secret = ConvertFrom-SetupSecureString $Secret
    } elseif ($PfxPath -and $PfxPassword) {
        $plaintext = ConvertFrom-SetupSecureString $PfxPassword
        try { $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxPath, $plaintext, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet) }
        finally { $plaintext = $null }
        try {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $header = @{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-SetupBase64Url $cert.GetCertHash()) }
            $claims = @{ aud = $tokenUri; iss = $AppId; sub = $AppId; jti = [Guid]::NewGuid().ToString(); nbf = $now - 60; exp = $now + 600 }
            $data = (ConvertTo-SetupBase64Url ([Text.Encoding]::UTF8.GetBytes(($header | ConvertTo-Json -Compress)))) + '.' + (ConvertTo-SetupBase64Url ([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))))
            $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
            try { $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($data), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1) }
            finally { $rsa.Dispose() }
            $body.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
            $body.client_assertion = "$data.$(ConvertTo-SetupBase64Url $signature)"
        } finally { $cert.Dispose() }
    } else { throw 'Validation requires a protected client secret or a certificate PFX and SecureString password.' }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $token = (Invoke-RestMethod -Method POST -Uri $tokenUri -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 30 -ErrorAction Stop).access_token
            if (-not $token) { throw 'Token response has no access_token.' }
            return $token
        }
        catch {
            if ($attempt -eq 3) { throw "Unable to obtain an app-only token for $Audience after bounded propagation retries. Check credential, consent and cloud. HTTP $([int]$_.Exception.Response.StatusCode)." }
            Start-Sleep -Seconds (3 * $attempt)
        }
    }
}

function Invoke-SetupProbe($Method, $Uri, $Token, $Body) {
    $params = @{ Method = $Method; Uri = $Uri; Headers = @{ Authorization = "Bearer $Token" }; TimeoutSec = 30; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress); $params.ContentType = 'application/json' }
    try { return ConvertTo-SetupData (Invoke-RestMethod @params) }
    catch {
        $status = [int]$_.Exception.Response.StatusCode
        throw "Probe failed with HTTP $status at $(([uri]$Uri).AbsolutePath). Check application role, license, endpoint availability or query."
    }
}

function Test-SetupAccess($AppId, $Manifest, $Selection, [SecureString]$Secret, $PfxPath, [SecureString]$PfxPassword) {
    $result = [ordered]@{}
    $cloudSpec = $Manifest.clouds[$Cloud]
    $tokens = @{}
    foreach ($resource in @('graph','activity')) {
        if ($Selection.permissions[$resource].Count -gt 0) {
            $audience = if ($resource -eq 'graph') { $cloudSpec.graph_base_url } else { $cloudSpec.activity_base_url }
            $tokens[$resource] = Get-SetupAppToken $AppId $audience $Manifest $Secret $PfxPath $PfxPassword
        }
    }
    if ($tokens.ContainsKey('activity')) {
        $base = "$($cloudSpec.activity_base_url)/api/v1.0/$TenantId/activity/feed"
        $publisher = if ($PublisherIdentifier) { '?PublisherIdentifier=' + [uri]::EscapeDataString($PublisherIdentifier) } else { '' }
        $subscriptions = @(Invoke-SetupProbe GET "$base/subscriptions/list$publisher" $tokens['activity'] $null)
        foreach ($type in $Selection.activity_content_types) {
            $found = @($subscriptions | Where-Object { $_.contentType -eq $type })
            if ($found.Count -eq 0) {
                $query = '?contentType=' + [uri]::EscapeDataString($type)
                if ($PublisherIdentifier) { $query += '&PublisherIdentifier=' + [uri]::EscapeDataString($PublisherIdentifier) }
                Invoke-SetupProbe POST "$base/subscriptions/start$query" $tokens['activity'] $null | Out-Null
                $result["activity/$type"] = 'started; feed may need time to warm up'
            } elseif ($found[0].status -eq 'enabled') {
                $result["activity/$type"] = 'enabled'
            } else {
                $result["activity/$type"] = 'existing subscription is disabled; no webhook or subscription was changed'
            }
        }
    }
    foreach ($name in $Selection.collectors) {
        if ($name -eq 'activity') { continue }
        $entry = $Manifest.collectors[$name]
        $version = $entry.api_version
        $uri = "$($cloudSpec.graph_base_url)/$version$($entry.endpoint)"
        if ($name -eq 'hunting') {
            $reply = Invoke-SetupProbe POST $uri $tokens['graph'] @{ query = $HuntingValidationQuery }
        } else {
            $reply = Invoke-SetupProbe GET "$uri`?`$top=1" $tokens['graph'] $null
        }
        $count = if ($name -eq 'hunting') { @($reply.results).Count } else { @($reply.value).Count }
        $result[$name] = if ($count -eq 0) { 'authorized; no records returned' } else { 'authorized; records returned' }
    }
    return $result
}

function Write-SetupArtifacts($App, $ClientSp, $Resources, $Selection, $CredentialInfo, $Validation, $OutputPath) {
    $manifestPath = Join-Path $OutputPath 'tenant-manifest.json'
    $configPath = Join-Path $OutputPath 'microsoft365.conf'
    $reportPath = Join-Path $OutputPath 'provisioning-report.json'
    $values = [ordered]@{
        schema_version = 1; tenant_id = $TenantId; cloud = $Cloud; application_id = $App.appId
        application_object_id = $App.id; service_principal_object_id = $ClientSp.id
        collectors = $Selection.collectors; authentication = $Authentication
        certificate_path = $CredentialInfo.certificate_path; certificate_pfx_path = $CredentialInfo.pfx_path
        publisher_identifier = $PublisherIdentifier
    }
    $certificateExpiry = $null
    if ($CredentialInfo.certificate_path) {
        $certificate = Get-SetupCertificate $CredentialInfo.certificate_path
        try { $certificateExpiry = $certificate.NotAfter.ToUniversalTime().ToString('o') }
        finally { $certificate.Dispose() }
    }
    $report = [ordered]@{
        tenant_id = $TenantId; cloud = $Cloud; application_id = $App.appId
        resource_permissions = [ordered]@{ graph = @($Selection.permissions.graph | Sort-Object); activity = @($Selection.permissions.activity | Sort-Object) }
        validation = $Validation; generated_utc = [DateTime]::UtcNow.ToString('o')
        credential_expiry_utc = if ($certificateExpiry) { $certificateExpiry } else { $CredentialInfo.secret_expiry_utc }
        note = 'Secrets and private keys are omitted. No tenant-wide auditing or license setting was changed.'
    }
    $quotedCollectors = ($Selection.collectors | ForEach-Object { '"' + $_ + '"' }) -join ', '
    $quotedContent = ($Selection.activity_content_types | ForEach-Object { ConvertTo-SetupLogstashString $_ }) -join ', '
    $quotedSignins = ($SigninTypes | ForEach-Object { ConvertTo-SetupLogstashString $_ }) -join ', '
    $lines = @('input {','  microsoft365 {',"    tenant_id => $(ConvertTo-SetupLogstashString $TenantId)", "    client_id => $(ConvertTo-SetupLogstashString $App.appId)", "    cloud => $(ConvertTo-SetupLogstashString $Cloud)", "    collectors => [$quotedCollectors]", "    activity_content_types => [$quotedContent]", "    state_path => $(ConvertTo-SetupLogstashString "/var/lib/logstash/microsoft365/$TenantId")")
    if ($OrganizationId) { $lines += "    organization_id => $(ConvertTo-SetupLogstashString $OrganizationId)" }
    if ($OrganizationName) { $lines += "    organization_name => $(ConvertTo-SetupLogstashString $OrganizationName)" }
    if ($PublisherIdentifier) { $lines += "    publisher_identifier => $(ConvertTo-SetupLogstashString $PublisherIdentifier)" }
    if ($IncludeDlp) { $lines += '    include_dlp => true' }
    if ($IncludeSensitiveDlp) { $lines += '    include_sensitive_dlp => true' }
    if ($IncludeConditionalAccess) { $lines += '    include_conditional_access => true' }
    if ($AllowBeta) { $lines += '    allow_beta => true' }
    if ('signin_beta' -in $Selection.collectors) { $lines += "    signin_types => [$quotedSignins]" }
    if ('hunting' -in $Selection.collectors) { $lines += "    hunting_queries_path => $(ConvertTo-SetupLogstashString $HuntingQueriesPath)" }
    if ($Authentication -eq 'Certificate') {
        $lines += '    certificate_path => "/etc/logstash/microsoft365/client.pfx"'
        $lines += '    certificate_password => "${M365_CERTIFICATE_PASSWORD}"'
    } else { $lines += '    client_secret => "${M365_CLIENT_SECRET}"' }
    $lines += @('  }','}')
    $instructions = @(
        'Import the PFX (certificate mode) or one-time secret into the Logstash host/keystore.',
        'Use logstash-keystore add M365_CERTIFICATE_PASSWORD or logstash-keystore add M365_CLIENT_SECRET.',
        'Protect and then remove the one-time secret file after import. Keep the PFX readable only by Logstash.',
        'Replace the generated certificate path with the deployed PFX path before starting Logstash.',
        'Run one input block per tenant and configure a persistent queue for durable delivery.'
    )
    [IO.File]::WriteAllText($manifestPath, ($values | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 20))
    [IO.File]::WriteAllLines($configPath, $lines)
    [IO.File]::WriteAllLines((Join-Path $OutputPath 'credential-import.txt'), $instructions)
    return @{ manifest = $manifestPath; report = $reportPath; config = $configPath }
}

function ConvertTo-SetupLogstashString([string]$Value) {
    if ($null -eq $Value) { throw 'Cannot render a null Logstash configuration value.' }
    return '"' + $Value.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n').Replace('$','\$') + '"'
}

function Write-SetupResume($App, $ClientSp, $CredentialInfo, $OutputPath) {
    $path = Join-Path $OutputPath 'tenant-manifest.json'
    if (Test-Path -LiteralPath $path) {
        $old = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ($old.tenant_id -ne $TenantId -or $old.cloud -ne $Cloud -or ($old.application_id -and $App -and $old.application_id -ne $App.appId)) {
            throw 'Output directory belongs to a different tenant, cloud or application.'
        }
    }
    $value = [ordered]@{
        schema_version = 1; tenant_id = $TenantId; cloud = $Cloud
        application_id = if ($App) { $App.appId } else { $null }
        application_object_id = if ($App) { $App.id } else { $null }
        service_principal_object_id = if ($ClientSp) { $ClientSp.id } else { $null }
        certificate_path = $CredentialInfo.certificate_path
        certificate_pfx_path = $CredentialInfo.pfx_path
    }
    [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 10))
}

function Invoke-SetupMain {
    $manifest = Get-SetupManifest
    $selection = Get-SetupSelection $manifest
    $plan = Get-SetupPlan $manifest $selection
    if ($Phase -eq 'Plan' -or $WhatIfPreference) { return $plan }

    $resume = $null
    if (-not $ResumeManifestPath) {
        $defaultResume = Join-Path $OutputDirectory 'tenant-manifest.json'
        if (Test-Path -LiteralPath $defaultResume) { $ResumeManifestPath = $defaultResume }
    }
    if ($ResumeManifestPath) {
        if (-not (Test-Path -LiteralPath $ResumeManifestPath)) { throw "Resume manifest not found: $ResumeManifestPath" }
        $resume = Get-Content -LiteralPath $ResumeManifestPath -Raw | ConvertFrom-Json -AsHashtable
        if ($resume.tenant_id -ne $TenantId -or $resume.cloud -ne $Cloud) { throw 'Resume manifest tenant/cloud does not match the target.' }
    }
    $appId = if ($ExistingApplicationId) { $ExistingApplicationId } elseif ($resume) { $resume.application_id } else { $null }
    if ($ExistingApplicationId -and $resume -and $ExistingApplicationId -ne $resume.application_id) { throw 'ExistingApplicationId and resume manifest disagree.' }
    if ($Phase -in @('Consent','Validate') -and -not $appId) { throw "$Phase requires -ExistingApplicationId or -ResumeManifestPath." }
    if ($Phase -in @('Provision','All') -and $Authentication -eq 'Certificate' -and -not ($CertificatePath -or $GenerateCertificate -or ($resume -and $resume.certificate_path))) {
        throw 'Certificate mode requires -CertificatePath, -GenerateCertificate or a resume manifest with a certificate path.'
    }
    if ($GenerateCertificate -and $Authentication -ne 'Certificate') { throw '-GenerateCertificate requires Certificate authentication.' }
    if ($GenerateCertificate -and $CertificatePath) { throw 'Use either -GenerateCertificate or -CertificatePath.' }
    $rotationUsesNewOutput = $false
    if ($GenerateCertificate -and $RotateCredential -and $resume -and $resume.certificate_path) {
        $rotationUsesNewOutput = [IO.Path]::GetFullPath($OutputDirectory) -ne [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ResumeManifestPath))
        if (-not $rotationUsesNewOutput) { throw 'Certificate rotation requires a new output directory so the previous credential remains available.' }
    }
    if ($Authentication -eq 'Certificate' -and $ClientSecret) { throw '-ClientSecret cannot be used with Certificate authentication.' }
    if ('hunting' -in $selection.collectors -and -not $HuntingQueriesPath) { throw 'The hunting collector requires -HuntingQueriesPath.' }
    Assert-SetupContext $manifest
    $resources = Get-SetupResources $manifest $selection ($Phase -in @('Provision','All'))
    $app = if ($appId) { Get-SetupApp $appId $manifest } else { $null }
    if ($appId -and -not $app) { throw "Explicit application ID $appId was not found in the target tenant." }
    $credentialInfo = @{ certificate_path = $CertificatePath; pfx_path = $CertificatePfxPath; secret_expiry_utc = $null }
    if (-not $credentialInfo.certificate_path -and $resume -and -not $rotationUsesNewOutput) { $credentialInfo.certificate_path = $resume.certificate_path }
    if (-not $credentialInfo.pfx_path -and $resume -and -not $rotationUsesNewOutput) { $credentialInfo.pfx_path = $resume.certificate_pfx_path }
    $secretForValidation = $ClientSecret
    if ($Phase -in @('Provision','All')) {
        Assert-SetupPrivateDirectory $OutputDirectory
        if ($Authentication -eq 'Certificate' -and $GenerateCertificate -and -not $credentialInfo.certificate_path) {
            $credentialInfo = New-SetupCertificate $OutputDirectory $CertificatePassword
        }
        Write-SetupResume $app $null $credentialInfo $OutputDirectory
        if (-not $app) {
            $app = Invoke-SetupGraph POST '/applications' @{ displayName = $DisplayName; signInAudience = 'AzureADMyOrg' } $manifest
            Write-SetupResume $app $null $credentialInfo $OutputDirectory
        }
        if ($app.signInAudience -ne 'AzureADMyOrg') { throw 'The selected application is not single-tenant.' }
        $appId = $app.appId
        $clientSp = Get-SetupSp $appId $manifest
        if (-not $clientSp) { $clientSp = Invoke-SetupGraph POST '/servicePrincipals' @{ appId = $appId } $manifest }
        Write-SetupResume $app $clientSp $credentialInfo $OutputDirectory
        [void](Merge-SetupRequiredAccess $app $resources $manifest)
        if ($Authentication -eq 'Certificate') {
            [void](Set-SetupCertificateCredential $app $credentialInfo.certificate_path $manifest $RotateCredential.IsPresent)
        } else {
            $secretInfo = Set-SetupSecretCredential $app $manifest $OutputDirectory $RotateCredential.IsPresent
            if ($secretInfo) {
                $secretForValidation = $secretInfo.value
                $credentialInfo.secret_expiry_utc = $secretInfo.expires_utc
            }
        }
    } else {
        $clientSp = Get-SetupSp $appId $manifest
        if (-not $clientSp) { throw 'Client service principal is missing. Run Provision first.' }
    }
    if ($Phase -in @('Consent','All')) { $consented = @(Grant-SetupRoles $clientSp $resources $manifest) }
    else { $consented = @() }
    $validation = $null
    if ($Phase -in @('Validate','All')) {
        if ($Authentication -eq 'Secret' -and -not $secretForValidation) {
            $secretPath = Join-Path $OutputDirectory 'm365-logstash-client-secret.txt'
            if (Test-Path -LiteralPath $secretPath) { $secretForValidation = ConvertTo-SecureString (Get-Content -LiteralPath $secretPath -Raw) -AsPlainText -Force }
        }
        $validation = Test-SetupAccess $appId $manifest $selection $secretForValidation $credentialInfo.pfx_path $CertificatePassword
    }
    Assert-SetupPrivateDirectory $OutputDirectory
    $artifacts = Write-SetupArtifacts $app $clientSp $resources $selection $credentialInfo $validation $OutputDirectory
    return [ordered]@{ tenant_id = $TenantId; cloud = $Cloud; application_id = $appId; consented_roles = $consented; validation = $validation; artifacts = $artifacts }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Phase -eq 'Plan' -or $WhatIfPreference) {
        Invoke-SetupMain
    } elseif ($PSCmdlet.ShouldProcess("tenant $TenantId in $Cloud and output $OutputDirectory", "Run $Phase")) {
        Invoke-SetupMain
    }
}
