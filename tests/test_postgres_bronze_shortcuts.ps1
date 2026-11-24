$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$deployment = Join-Path $root 'scripts\deploy-sql-bronze-shortcuts.ps1'
$workspaceId = [guid]'00000000-0000-0000-0000-000000000001'
$subscriptionId = [guid]'00000000-0000-0000-0000-000000000002'
$tenantId = [guid]'00000000-0000-0000-0000-000000000003'
$capacityId = [guid]'00000000-0000-0000-0000-000000000004'
$mirrorId = [guid]'00000000-0000-0000-0000-000000000005'
$bronzeId = [guid]'00000000-0000-0000-0000-000000000006'
$connectionId = [guid]'00000000-0000-0000-0000-000000000007'
$operationId = [guid]'00000000-0000-0000-0000-000000000008'
$connectionPath = 'fixture-server;fixture-database'
$roomPath = 'Tables/verified_schema/facility_room'
$closurePath = 'Tables/verified_schema/facility_closure'
$global:MacawPostgresShortcutTest = $null

function Reset-Fixture {
    $shortcuts = [Collections.Generic.List[object]]::new()
    $shortcuts.Add([pscustomobject]@{
        path = '/Tables'; name = 'PostGre'
        target = [pscustomobject]@{
            oneLake = [pscustomobject]@{
                workspaceId = $workspaceId.ToString(); itemId = $mirrorId.ToString()
                path = 'Tables/verified_schema'
            }
        }
    })
    $global:MacawPostgresShortcutTest = @{
        Shortcuts = $shortcuts
        Folder = $false
        Posts = 0
        Puts = 0
        ConnectionPath = $connectionPath
        ConnectivityType = 'VirtualNetworkGateway'
        CredentialType = 'OAuth2'
        Encryption = 'Encrypted'
        SourceType = 'AzurePostgreSql'
        DefinitionConnection = $connectionId.ToString()
        MountedTables = @('facility_room', 'facility_closure')
        OmitMountedTables = $false
        MirrorStatus = 'Running'
        RoomStatus = 'Replicating'
        RoomSync = '2026-01-01T00:00:00Z'
        StatusCount = 2
        Continuation = 'token'
        LongRunningDefinition = $false
        MissingSource = ''
        DeploymentBlocked = $false
    }
}

function az {
    $audience = if ($args -contains 'https://storage.azure.com/') {
        'https://storage.azure.com/'
    } else {
        'https://api.fabric.microsoft.com'
    }
    $claims = @{ tid = $tenantId.ToString(); aud = $audience } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).
        TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $global:LASTEXITCODE = 0
    "header.$payload.signature"
}

function Assert-FabricHeader {
    param($Headers)
    if ($Headers['x-ms-fabric-skill'] -ne 'e2e-medallion-architecture') {
        throw 'Missing Fabric skill attribution.'
    }
}

function Get-FixtureDefinition {
    $mounted = @($global:MacawPostgresShortcutTest.MountedTables | ForEach-Object {
        @{ source = @{ typeProperties = @{ schemaName = 'public'; tableName = $_ } } }
    })
    $definition = @{
        properties = @{
            source = @{
                type = $global:MacawPostgresShortcutTest.SourceType
                typeProperties = @{ connection = $global:MacawPostgresShortcutTest.DefinitionConnection }
            }
            target = @{
                type = 'MountedRelationalDatabase'
                typeProperties = @{ format = 'Delta' }
            }
            mountedTables = $mounted
        }
    }
    if ($global:MacawPostgresShortcutTest.OmitMountedTables) {
        $definition.properties.Remove('mountedTables')
    }
    $payload = $definition | ConvertTo-Json -Depth 12 -Compress
    $part = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    @{ definition = @{ parts = @(@{ path = 'mirroring.json'; payloadType = 'InlineBase64'; payload = $part }) } } |
        ConvertTo-Json -Depth 12 -Compress
}

function Invoke-RestMethod {
    param([string]$Method = 'Get', [string]$Uri, $Headers, [string]$ContentType, [string]$Body)
    Assert-FabricHeader $Headers
    $parsed = [uri]$Uri
    $path = $parsed.AbsolutePath
    if ($path -eq '/v1/workspaces') {
        return [pscustomobject]@{
            value = @([pscustomobject]@{ id = $workspaceId.ToString(); capacityId = $capacityId.ToString() })
        }
    }
    if ($path -eq '/v1/capacities') {
        return [pscustomobject]@{
            value = @([pscustomobject]@{ id = $capacityId.ToString(); state = 'Active' })
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/items") {
        return [pscustomobject]@{
            value = @(
                [pscustomobject]@{ id = $mirrorId.ToString(); type = 'MirroredDatabase'; displayName = 'FacilitiesMirror' }
                [pscustomobject]@{ id = $bronzeId.ToString(); type = 'Lakehouse'; displayName = 'MacawEducationBronze' }
            )
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/mirroredDatabases/$mirrorId") {
        return [pscustomobject]@{
            id = $mirrorId.ToString(); workspaceId = $workspaceId.ToString()
            type = 'MirroredDatabase'; displayName = 'FacilitiesMirror'
            properties = [pscustomobject]@{
                oneLakeTablesPath = "https://onelake.dfs.fabric.microsoft.com/$workspaceId/$mirrorId/Tables"
                sqlEndpointProperties = [pscustomobject]@{ provisioningStatus = 'Success' }
            }
        }
    }
    if ($path -eq "/v1/connections/$connectionId") {
        return [pscustomobject]@{
            id = $connectionId.ToString()
            connectivityType = $global:MacawPostgresShortcutTest.ConnectivityType
            connectionDetails = [pscustomobject]@{ path = $global:MacawPostgresShortcutTest.ConnectionPath }
            credentialDetails = [pscustomobject]@{
                credentialType = $global:MacawPostgresShortcutTest.CredentialType
                connectionEncryption = $global:MacawPostgresShortcutTest.Encryption
            }
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/lakehouses/$bronzeId") {
        return [pscustomobject]@{
            id = $bronzeId.ToString(); workspaceId = $workspaceId.ToString()
            description = 'Macaw education PoC Bronze lakehouse.'
            properties = [pscustomobject]@{
                defaultSchema = 'dbo'
                oneLakeFilesPath = "https://onelake.dfs.fabric.microsoft.com/$workspaceId/$bronzeId/Files"
                sqlEndpointProperties = [pscustomobject]@{ provisioningStatus = 'Success' }
            }
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/items/$bronzeId/shortcuts") {
        return [pscustomobject]@{ value = @($global:MacawPostgresShortcutTest.Shortcuts.ToArray()) }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/mirroredDatabases/$mirrorId/getMirroringStatus") {
        if ($Method -ne 'Post') { throw 'Mirror status must use POST.' }
        return [pscustomobject]@{ status = $global:MacawPostgresShortcutTest.MirrorStatus }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/mirroredDatabases/$mirrorId/getTablesMirroringStatus") {
        if ($Method -ne 'Post') { throw 'Table status must use POST, including continuation requests.' }
        $room = [pscustomobject]@{
            sourceObjectType = 'Table'; sourceSchemaName = 'public'; sourceTableName = 'facility_room'
            status = $global:MacawPostgresShortcutTest.RoomStatus
            metrics = [pscustomobject]@{ lastSyncDateTime = $global:MacawPostgresShortcutTest.RoomSync }
        }
        $closure = [pscustomobject]@{
            sourceObjectType = 'Table'; sourceSchemaName = 'public'; sourceTableName = 'facility_closure'
            status = 'Replicating'; metrics = [pscustomobject]@{ lastSyncDateTime = '2026-01-01T00:00:00Z' }
        }
        if ($global:MacawPostgresShortcutTest.StatusCount -eq 1) {
            return [pscustomobject]@{ data = @($room) }
        }
        if (-not $parsed.Query) {
            if ($global:MacawPostgresShortcutTest.Continuation -eq 'hostile') {
                return [pscustomobject]@{ data = @($room); continuationUri = 'https://example.invalid/steal' }
            }
            if ($global:MacawPostgresShortcutTest.Continuation -eq 'wrong-path') {
                return [pscustomobject]@{
                    data = @($room); continuationUri = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId/items"
                }
            }
            if ($global:MacawPostgresShortcutTest.Continuation -eq 'repeat') {
                return [pscustomobject]@{ data = @($room); continuationUri = $Uri }
            }
            if ($global:MacawPostgresShortcutTest.Continuation -eq 'uri') {
                return [pscustomobject]@{
                    data = @($room); continuationUri = "$Uri`?continuationToken=next%2B%2F%3D"
                }
            }
            return [pscustomobject]@{ data = @($room); continuationToken = 'next+/=' }
        }
        if ($parsed.Query -cne '?continuationToken=next%2B%2F%3D') {
            throw 'The opaque continuation token was not URL-encoded correctly.'
        }
        return [pscustomobject]@{ data = @($closure) }
    }
    throw "Unexpected fixture request: $Method $path"
}

function Invoke-WebRequest {
    param([string]$Method = 'Get', [string]$Uri, $Headers, [string]$ContentType, [string]$Body, [switch]$SkipHttpErrorCheck)
    $path = ([uri]$Uri).AbsolutePath
    if ($path -like '/v1/*') { Assert-FabricHeader $Headers }
    if ($path -eq "/v1/workspaces/$workspaceId/mirroredDatabases/$mirrorId/getDefinition" -and $Method -eq 'Post') {
        if ($global:MacawPostgresShortcutTest.LongRunningDefinition) {
            return [pscustomobject]@{
                StatusCode = 202; Headers = @{ 'x-ms-operation-id' = $operationId.ToString(); 'Retry-After' = '1' }
            }
        }
        return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = (Get-FixtureDefinition) }
    }
    if ($path -eq "/v1/operations/$operationId") {
        return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{"status":"Succeeded"}' }
    }
    if ($path -eq "/v1/operations/$operationId/result") {
        return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = (Get-FixtureDefinition) }
    }
    if ($Method -eq 'Head') {
        if ($path -eq "/$workspaceId/$bronzeId/Files/postgres_mirror") {
            $status = if ($global:MacawPostgresShortcutTest.Folder) { 200 } else { 404 }
            return [pscustomobject]@{ StatusCode = $status; Headers = @{ 'x-ms-resource-type' = 'directory' } }
        }
        if ($path -match "/$workspaceId/$mirrorId/Tables/verified_schema/(facility_room|facility_closure)/_delta_log$") {
            $status = if ($Matches[1] -eq $global:MacawPostgresShortcutTest.MissingSource) { 404 } else { 200 }
            return [pscustomobject]@{ StatusCode = $status; Headers = @{} }
        }
        if ($path -match "/$workspaceId/$bronzeId/Tables/PostGre/(facility_room|facility_closure)/_delta_log$") {
            return [pscustomobject]@{ StatusCode = 200; Headers = @{} }
        }
        if ($path -match "/$workspaceId/$bronzeId/Files/postgres_mirror/(facility_room|facility_closure)$") {
            return [pscustomobject]@{ StatusCode = 404; Headers = @{} }
        }
    }
    if ($Method -eq 'Put' -and $path -eq "/$workspaceId/$bronzeId/Files/postgres_mirror") {
        if ($Headers['If-None-Match'] -ne '*' -or $global:MacawPostgresShortcutTest.Folder) {
            throw 'Folder creation was not protected against an existing path.'
        }
        $global:MacawPostgresShortcutTest.Puts++
        $global:MacawPostgresShortcutTest.Folder = $true
        return [pscustomobject]@{ StatusCode = 201; Headers = @{} }
    }
    if ($Method -eq 'Post' -and $path -eq "/v1/workspaces/$workspaceId/items/$bronzeId/shortcuts") {
        $request = $Body | ConvertFrom-Json
        $expectedPath = if ($request.name -ceq 'facility_room') { $roomPath } else { $closurePath }
        if ($request.path -cne 'Files/postgres_mirror' -or
            $request.name -cnotin @('facility_room', 'facility_closure') -or
            $request.target.oneLake.workspaceId -ne $workspaceId.ToString() -or
            $request.target.oneLake.itemId -ne $mirrorId.ToString() -or
            $request.target.oneLake.path -cne $expectedPath) {
            throw 'The PostgreSQL shortcut request is not allowlisted.'
        }
        $global:MacawPostgresShortcutTest.Posts++
        $request.path = "/$($request.path)"
        $global:MacawPostgresShortcutTest.Shortcuts.Add($request)
        return [pscustomobject]@{ StatusCode = 201; Headers = @{} }
    }
    throw "Unexpected fixture request: $Method $path"
}

function Start-Sleep { param([int]$Seconds) }

function Test-Path {
    param([string]$LiteralPath)
    if ($LiteralPath -like '*POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED') {
        return $global:MacawPostgresShortcutTest.DeploymentBlocked
    }
    return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}

function Invoke-Deployment {
    param([switch]$PreflightOnly, [switch]$VerifyOnly, [string]$RoomPath = $roomPath)
    & $deployment -SubscriptionId $subscriptionId -TenantId $tenantId `
        -WorkspaceId $workspaceId -DatabaseItemId $mirrorId -SourceKind AzurePostgreSql `
        -PostgresMirrorName 'FacilitiesMirror' -PostgresConnectionId $connectionId `
        -PostgresConnectionPath $connectionPath -PostgresRoomPath $RoomPath `
        -PostgresClosurePath $closurePath -PreflightOnly:$PreflightOnly -VerifyOnly:$VerifyOnly
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Expected)
    try { & $Action } catch {
        if ($_.Exception.Message -like "*$Expected*") { return }
        throw
    }
    throw "Expected an error containing '$Expected'."
}

function Assert-NoWrites {
    if ($global:MacawPostgresShortcutTest.Posts -ne 0 -or $global:MacawPostgresShortcutTest.Puts -ne 0) {
        throw 'A shortcut or directory was created during read-only verification.'
    }
}

try {
    Reset-Fixture
    $global:MacawPostgresShortcutTest.DeploymentBlocked = $true
    $marker = Join-Path $root 'fabric\POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED'
    if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $marker)) {
        throw 'The PostgreSQL deployment guard is missing from this checkout.'
    }
    Assert-Throws { Invoke-Deployment } 'shortcut deployment is blocked'
    Assert-NoWrites
    Invoke-Deployment -PreflightOnly
    Assert-NoWrites
    Invoke-Deployment -VerifyOnly
    Assert-NoWrites
    Assert-Throws { Invoke-Deployment -PreflightOnly -VerifyOnly } 'cannot be combined'
    Assert-NoWrites

    Reset-Fixture
    $global:MacawPostgresShortcutTest.ConnectivityType = 'ShareableCloud'
    Invoke-Deployment -PreflightOnly
    Assert-NoWrites

    Reset-Fixture
    $global:MacawPostgresShortcutTest.RoomSync = [DateTime]::SpecifyKind(
        [DateTime]'2026-01-01T00:00:00', [DateTimeKind]::Utc
    )
    Invoke-Deployment -PreflightOnly
    Assert-NoWrites

    Reset-Fixture
    Assert-Throws { Invoke-Deployment } 'legacy Files shortcuts is retired'
    Invoke-Deployment -VerifyOnly
    Assert-NoWrites

    Reset-Fixture
    $global:MacawPostgresShortcutTest.LongRunningDefinition = $true
    $global:MacawPostgresShortcutTest.Continuation = 'uri'
    Invoke-Deployment -PreflightOnly
    Assert-NoWrites

    Reset-Fixture
    $global:MacawPostgresShortcutTest.Shortcuts.Clear()
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'schema shortcut is missing or ambiguous'
    Assert-NoWrites

    Reset-Fixture
    $global:MacawPostgresShortcutTest.Shortcuts[0].target.oneLake.path = 'Tables/another_schema'
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'unexpected or delegated target'
    Assert-NoWrites

    Reset-Fixture
    $global:MacawPostgresShortcutTest.Shortcuts.Add([pscustomobject]@{
        path = '/Files/postgres_mirror'; name = 'facility_room'; target = [pscustomobject]@{}
    })
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'Legacy PostgreSQL Files shortcuts still exist'
    Assert-NoWrites

    Reset-Fixture
    Assert-Throws { Invoke-Deployment -PreflightOnly -RoomPath 'Tables/../facility_room' } 'Delta paths'
    Assert-NoWrites

    foreach ($case in @(
        @{ Property = 'ConnectionPath'; Value = 'another-server;database'; Error = 'reviewed encrypted cloud or VNet gateway connection' }
        @{ Property = 'ConnectivityType'; Value = 'OnPremisesGateway'; Error = 'reviewed encrypted cloud or VNet gateway connection' }
        @{ Property = 'CredentialType'; Value = 'Basic'; Error = 'reviewed encrypted cloud or VNet gateway connection' }
        @{ Property = 'Encryption'; Value = 'Any'; Error = 'reviewed encrypted cloud or VNet gateway connection' }
        @{ Property = 'SourceType'; Value = 'AzureSqlDatabase'; Error = 'expected PostgreSQL connection' }
        @{ Property = 'DefinitionConnection'; Value = $operationId.ToString(); Error = 'expected PostgreSQL connection' }
        @{ Property = 'OmitMountedTables'; Value = $true; Error = 'explicitly select only' }
        @{ Property = 'MountedTables'; Value = @('facility_room'); Error = 'explicitly select only' }
        @{ Property = 'MountedTables'; Value = @('facility_room', 'facility_room'); Error = 'exactly once' }
        @{ Property = 'MirrorStatus'; Value = 'Paused'; Error = 'not running cleanly' }
        @{ Property = 'RoomStatus'; Value = 'Snapshotting'; Error = 'not replicating' }
        @{ Property = 'RoomSync'; Value = 'invalid'; Error = 'valid sync timestamp' }
        @{ Property = 'RoomSync'; Value = '2026-01-01'; Error = 'valid sync timestamp' }
        @{ Property = 'RoomSync'; Value = ([DateTime]'2026-01-01T00:00:00'); Error = 'valid sync timestamp' }
        @{ Property = 'StatusCount'; Value = 1; Error = 'exactly the two expected' }
        @{ Property = 'Continuation'; Value = 'hostile'; Error = 'unexpected table-status continuation URL' }
        @{ Property = 'Continuation'; Value = 'wrong-path'; Error = 'unexpected table-status continuation URL' }
        @{ Property = 'Continuation'; Value = 'repeat'; Error = 'repeated or excessive' }
        @{ Property = 'MissingSource'; Value = 'facility_room'; Error = "Delta log for 'facility_room' is not accessible" }
    )) {
        Reset-Fixture
        $global:MacawPostgresShortcutTest[$case.Property] = $case.Value
        Assert-Throws { Invoke-Deployment -PreflightOnly } $case.Error
        Assert-NoWrites
    }
} finally {
    Remove-Variable -Name MacawPostgresShortcutTest -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'PostgreSQL Bronze shortcut verification and preflight tests passed.'
