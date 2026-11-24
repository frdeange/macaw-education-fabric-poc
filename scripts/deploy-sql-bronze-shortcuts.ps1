[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$WorkspaceId,

    [Parameter(Mandatory)]
    [guid]$DatabaseItemId,

    [string]$SourceDatabaseName = 'MacawEducation',
    [ValidateSet('FabricSql', 'AzurePostgreSql')]
    [string]$SourceKind = 'FabricSql',
    [string]$PostgresMirrorName,
    [guid]$PostgresConnectionId = [guid]::Empty,
    [string]$PostgresConnectionPath,
    [string]$PostgresRoomPath,
    [string]$PostgresClosurePath,
    [string]$BronzeName = 'MacawEducationBronze',
    [string]$SkillAttribution = 'e2e-medallion-architecture',
    [switch]$PreflightOnly,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$contractFile = if ($SourceKind -eq 'FabricSql') {
    'sql-bronze-tables.json'
} else {
    'postgres-bronze-tables.json'
}
$contractPath = Join-Path $PSScriptRoot "..\fabric\$contractFile"
$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
$tables = @($contract.tables)
$schema = if ($SourceKind -eq 'FabricSql') { 'dbo' } else { 'public' }
if ($contract.sourceSchema -cne $schema -or $tables.Count -eq 0 -or
    @($tables.name | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
    throw 'The Bronze table contract is invalid or contains duplicate tables.'
}
foreach ($table in $tables) {
    if ($table.name -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$' -or
        $table.name -like 'Analytics*' -or $table.name -like 'Security*' -or
        @($table.keyColumns).Count -eq 0 -or
        @($table.keyColumns | Where-Object { $_ -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$' }).Count -gt 0 -or
        @($table.keyColumns | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw "Invalid or excluded table in the Bronze contract: '$($table.name)'."
    }
}
if ([string]::IsNullOrWhiteSpace($SourceDatabaseName) -or
    [string]::IsNullOrWhiteSpace($BronzeName) -or
    [string]::IsNullOrWhiteSpace($SkillAttribution)) {
    throw 'Source name, Bronze name and Fabric skill attribution must not be empty.'
}
$targets = @{}
$sourceType = 'SQLDatabase'
$sourceName = $SourceDatabaseName
$folderName = 'sql_mirror'
$sourceLabel = 'SQL'
$bronzeSchema = 'sql'
$schemaTarget = "Tables/$($contract.sourceSchema)"
if ($PreflightOnly -and ($VerifyOnly -or $SourceKind -ne 'AzurePostgreSql')) {
    throw 'Preflight-only mode is available for PostgreSQL and cannot be combined with verify-only mode.'
}
if ($SourceKind -eq 'AzurePostgreSql') {
    $deploymentBlock = Join-Path $PSScriptRoot '..\fabric\POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED'
    if (-not $VerifyOnly -and -not $PreflightOnly -and (Test-Path -LiteralPath $deploymentBlock)) {
        throw 'PostgreSQL Bronze shortcut deployment is blocked pending source, mirror and Lakehouse security validation.'
    }
    if ([string]::IsNullOrWhiteSpace($PostgresMirrorName) -or
        $PostgresConnectionId -eq [guid]::Empty -or
        [string]::IsNullOrWhiteSpace($PostgresConnectionPath) -or
        $PostgresRoomPath -cnotmatch '\ATables/(?:[A-Za-z_][A-Za-z0-9_]*/)*facility_room\z' -or
        $PostgresClosurePath -cnotmatch '\ATables/(?:[A-Za-z_][A-Za-z0-9_]*/)*facility_closure\z' -or
        $PostgresRoomPath.Substring(0, $PostgresRoomPath.Length - 'facility_room'.Length) -cne
            $PostgresClosurePath.Substring(0, $PostgresClosurePath.Length - 'facility_closure'.Length) -or
        $tables.Count -ne 2 -or 'facility_room' -cnotin $tables.name -or
        'facility_closure' -cnotin $tables.name) {
        throw 'The PostgreSQL mirror, reviewed connection, Delta paths or table contract is invalid.'
    }
    $targets['facility_room'] = $PostgresRoomPath
    $targets['facility_closure'] = $PostgresClosurePath
    $sourceType = 'MirroredDatabase'
    $sourceName = $PostgresMirrorName
    $folderName = 'postgres_mirror'
    $sourceLabel = 'PostgreSQL'
    $bronzeSchema = 'PostGre'
    $schemaTarget = $PostgresRoomPath.Substring(0, $PostgresRoomPath.LastIndexOf('/'))
} else {
    foreach ($table in $tables) {
        $targets[$table.name] = "Tables/$($contract.sourceSchema)/$($table.name)"
    }
}
if (-not $VerifyOnly -and -not $PreflightOnly) {
    throw 'Creation of legacy Files shortcuts is retired. Manage schema shortcuts in Fabric and use -VerifyOnly.'
}

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$headers['x-ms-fabric-skill'] = $SkillAttribution
$api = 'https://api.fabric.microsoft.com/v1'
$base = "$api/workspaces/$WorkspaceId"

$workspaces = @(Get-FabricItems -Uri "$api/workspaces" -Headers $headers |
    Where-Object { $_.id -eq $WorkspaceId.ToString() })
if ($workspaces.Count -ne 1 -or
    -not $workspaces[0].PSObject.Properties['capacityId'] -or -not $workspaces[0].capacityId) {
    throw 'The target workspace was not uniquely found on a Fabric capacity.'
}
$capacities = @(Get-FabricItems -Uri "$api/capacities" -Headers $headers |
    Where-Object { $_.id -eq $workspaces[0].capacityId })
if ($capacities.Count -ne 1 -or $capacities[0].state -ne 'Active') {
    throw 'The workspace capacity is not uniquely visible and active.'
}

$items = @(Get-FabricItems -Uri "$base/items" -Headers $headers)
$source = @($items | Where-Object {
    $_.type -eq $sourceType -and $_.id -eq $DatabaseItemId.ToString() -and
    $_.displayName -ceq $sourceName
})
$bronze = @($items | Where-Object {
    $_.type -eq 'Lakehouse' -and $_.displayName -ceq $BronzeName
})
if ($source.Count -ne 1 -or $bronze.Count -ne 1) {
    throw 'The source database or Bronze lakehouse was not uniquely found.'
}
if ($SourceKind -eq 'AzurePostgreSql') {
    . (Join-Path $PSScriptRoot 'postgres-mirror.ps1')
    Test-PostgresMirror -WorkspaceId $WorkspaceId -MirrorItemId $DatabaseItemId `
        -ConnectionId $PostgresConnectionId -ConnectionPath $PostgresConnectionPath `
        -MirrorName $PostgresMirrorName -Tables $tables -Headers $headers
}
$lakehouse = Invoke-RestMethod -Uri "$base/lakehouses/$($bronze[0].id)" -Headers $headers
if ($lakehouse.id -ne $bronze[0].id -or $lakehouse.workspaceId -ne $WorkspaceId.ToString() -or
    $lakehouse.description -ne 'Macaw education PoC Bronze lakehouse.' -or
    $lakehouse.properties.defaultSchema -ne 'dbo' -or
    $lakehouse.properties.sqlEndpointProperties.provisioningStatus -ne 'Success') {
    throw 'The Bronze lakehouse does not match the ready, schema-enabled project item.'
}
$filesUri = [uri]$lakehouse.properties.oneLakeFilesPath
$expectedFilesPath = "/$WorkspaceId/$($bronze[0].id)/Files"
if ($filesUri.Scheme -ne 'https' -or
    $filesUri.Host -notmatch '(^|-)onelake\.dfs\.fabric\.microsoft\.com$' -or
    $filesUri.AbsolutePath.TrimEnd('/') -ne $expectedFilesPath) {
    throw 'The Bronze OneLake Files path does not match the expected workspace and item.'
}
$storageRoot = $filesUri.GetLeftPart([UriPartial]::Authority)

$storageToken = & az account get-access-token --subscription $SubscriptionId.ToString() `
    --resource 'https://storage.azure.com/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $storageToken) {
    throw 'Unable to acquire a OneLake access token for the selected subscription.'
}
$claimsPart = $storageToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
$claimsPart = $claimsPart.PadRight($claimsPart.Length + ((4 - $claimsPart.Length % 4) % 4), '=')
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($claimsPart)) | ConvertFrom-Json
if ($claims.tid -ne $TenantId.ToString() -or ([string]$claims.aud).TrimEnd('/') -ne 'https://storage.azure.com') {
    throw 'The OneLake token belongs to a different tenant or audience.'
}
$storageHeaders = @{ Authorization = "Bearer $storageToken"; 'x-ms-version' = '2023-08-03' }

try {
    foreach ($table in $tables) {
        $sourceLog = "$storageRoot/$WorkspaceId/$DatabaseItemId/$($targets[$table.name])/_delta_log"
        $sourceResponse = Invoke-WebRequest -Method Head -Uri $sourceLog -Headers $storageHeaders -SkipHttpErrorCheck
        if ($sourceResponse.StatusCode -ne 200) {
            throw "The mirrored Delta log for '$($table.name)' is not accessible: HTTP $($sourceResponse.StatusCode)."
        }
    }

    if ($PreflightOnly) {
        Write-Host 'PostgreSQL mirror and source Delta-log preflight passed; no shortcuts or directories were created.'
        Write-Host 'Validate row equality, freshness, pipeline access and restricted-user isolation separately.'
        return
    }

    $shortcuts = @(Get-FabricItems -Uri "$base/items/$($bronze[0].id)/shortcuts" -Headers $headers)
    $matches = @($shortcuts | Where-Object {
        $_.path.TrimStart('/') -ceq 'Tables' -and $_.name -ceq $bronzeSchema
    })
    if ($matches.Count -ne 1) {
        throw "The $sourceLabel schema shortcut is missing or ambiguous in verify-only mode."
    }
    $target = $matches[0].target
    if (-not $target.PSObject.Properties['oneLake'] -or -not $target.oneLake -or
        $target.oneLake.workspaceId -ne $WorkspaceId.ToString() -or
        $target.oneLake.itemId -ne $DatabaseItemId.ToString() -or
        $target.oneLake.path -cne $schemaTarget -or
        ($target.oneLake.PSObject.Properties['connectionId'] -and $target.oneLake.connectionId)) {
        throw "The $sourceLabel schema shortcut points to an unexpected or delegated target."
    }
    $legacyPath = "Files/$folderName"
    $legacyShortcuts = @($shortcuts | Where-Object {
        $parent = $_.path.TrimStart('/')
        ($parent -ceq 'Files' -and $_.name -ceq $folderName) -or
        $parent -ceq $legacyPath -or
        $parent.StartsWith("$legacyPath/", [StringComparison]::Ordinal)
    })
    if ($legacyShortcuts.Count -gt 0) {
        throw "Legacy $sourceLabel Files shortcuts still exist; inspect them before proceeding."
    }
    foreach ($table in $tables) {
        $logResponse = Invoke-WebRequest -Method Head `
            -Uri "$storageRoot/$WorkspaceId/$($bronze[0].id)/Tables/$bronzeSchema/$($table.name)/_delta_log" `
            -Headers $storageHeaders -SkipHttpErrorCheck
        if ($logResponse.StatusCode -ne 200) {
            throw "Shortcut '$($table.name)' cannot read its Delta log: HTTP $($logResponse.StatusCode)."
        }
    }
    Write-Host "Verified $($tables.Count) reviewed $sourceLabel tables through the Bronze '$bronzeSchema' schema shortcut."
    Write-Host 'A schema shortcut exposes the entire source schema, not just the reviewed table contract.'
    Write-Host 'No data was materialized and no permissions were granted. Restricted access remains unverified.'
} finally {
    $storageHeaders.Clear()
    $headers.Clear()
    $storageToken = $null
}
