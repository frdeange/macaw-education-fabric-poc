function Test-MirrorSyncTimestamp {
    param($Value)

    if ($Value -is [DateTime]) {
        return $Value.Kind -eq [DateTimeKind]::Utc
    }
    if ($Value -is [DateTimeOffset]) {
        return $Value.Offset -eq [TimeSpan]::Zero
    }
    if ($Value -isnot [string] -or
        $Value -cnotmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z\z') {
        return $false
    }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse($Value, [ref]$parsed)
}

function Test-PostgresMirror {
    param(
        [guid]$WorkspaceId,
        [guid]$MirrorItemId,
        [guid]$ConnectionId,
        [string]$ConnectionPath,
        [string]$MirrorName,
        [object[]]$Tables,
        [hashtable]$Headers
    )

    $api = 'https://api.fabric.microsoft.com/v1'
    $mirrorUri = "$api/workspaces/$WorkspaceId/mirroredDatabases/$MirrorItemId"
    $mirror = Invoke-RestMethod -Uri $mirrorUri -Headers $Headers
    if ($mirror.id -ne $MirrorItemId.ToString() -or
        $mirror.workspaceId -ne $WorkspaceId.ToString() -or
        $mirror.type -ne 'MirroredDatabase' -or
        $mirror.displayName -cne $MirrorName -or
        $mirror.properties.sqlEndpointProperties.provisioningStatus -ne 'Success') {
        throw 'The PostgreSQL mirror metadata or SQL endpoint does not match the expected item.'
    }
    $tablesUri = [uri]$mirror.properties.oneLakeTablesPath
    if ($tablesUri.Scheme -ne 'https' -or
        $tablesUri.Host -notmatch '(^|-)onelake\.dfs\.fabric\.microsoft\.com$' -or
        $tablesUri.AbsolutePath.TrimEnd('/') -cne "/$WorkspaceId/$MirrorItemId/Tables") {
        throw 'The PostgreSQL mirror OneLake Tables path does not match the expected item.'
    }

    $connection = Invoke-RestMethod -Uri "$api/connections/$ConnectionId" -Headers $Headers
    if ($connection.id -ne $ConnectionId.ToString() -or
        $connection.connectivityType -notin @('VirtualNetworkGateway', 'ShareableCloud') -or
        $connection.connectionDetails.path -cne $ConnectionPath -or
        $connection.credentialDetails.credentialType -ne 'OAuth2' -or
        $connection.credentialDetails.connectionEncryption -ne 'Encrypted') {
        throw 'The PostgreSQL mirror connection does not match the reviewed encrypted cloud or VNet gateway connection.'
    }

    $response = Invoke-WebRequest -Method Post -Uri "$mirrorUri/getDefinition" -Headers $Headers `
        -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
    if ($response.StatusCode -eq 202) {
        Wait-FabricOperation -Response $response -Headers $Headers
        $operationId = [Guid]::Empty
        if (-not [Guid]::TryParse([string]@($response.Headers['x-ms-operation-id'])[0], [ref]$operationId)) {
            throw 'The mirror definition operation did not return a valid ID.'
        }
        $response = Invoke-WebRequest -Uri "$api/operations/$operationId/result" -Headers $Headers `
            -SkipHttpErrorCheck
    }
    if ($response.StatusCode -ne 200) {
        throw "The mirror definition could not be retrieved: HTTP $($response.StatusCode)."
    }
    $definition = $response.Content | ConvertFrom-Json -AsHashtable
    $parts = @($definition['definition']['parts'] | Where-Object { $_['path'] -ceq 'mirroring.json' })
    if ($parts.Count -ne 1 -or $parts[0]['payloadType'] -cne 'InlineBase64') {
        throw 'The PostgreSQL mirror does not have one supported mirroring definition.'
    }
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[0]['payload']))
    $properties = ($payload | ConvertFrom-Json -AsHashtable)['properties']
    if ($properties['source']['type'] -cne 'AzurePostgreSql' -or
        $properties['source']['typeProperties']['connection'] -ne $ConnectionId.ToString() -or
        $properties['target']['type'] -cne 'MountedRelationalDatabase' -or
        $properties['target']['typeProperties']['format'] -cne 'Delta') {
        throw 'The mirror definition does not select the expected PostgreSQL connection and Delta target.'
    }
    $mounted = @($properties['mountedTables'])
    if ($mounted.Count -ne $Tables.Count) {
        throw 'The mirror definition must explicitly select only the facilities tables.'
    }
    foreach ($table in $Tables) {
        $matches = @($mounted | Where-Object {
            $_['source']['typeProperties']['schemaName'] -ceq 'public' -and
            $_['source']['typeProperties']['tableName'] -ceq $table.name
        })
        if ($matches.Count -ne 1) {
            throw "The mirror definition must select public.$($table.name) exactly once."
        }
    }

    $status = Invoke-RestMethod -Method Post -Uri "$mirrorUri/getMirroringStatus" -Headers $Headers `
        -ContentType 'application/json' -Body '{}'
    if ($status.status -cne 'Running' -or
        ($status.PSObject.Properties['error'] -and $status.error)) {
        throw "PostgreSQL mirroring is not running cleanly: $($status.status)."
    }

    $statusUri = "$mirrorUri/getTablesMirroringStatus"
    $next = $statusUri
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $statuses = @()
    while ($next) {
        $resolved = [Uri]::new([Uri]'https://api.fabric.microsoft.com', $next)
        if ($resolved.Scheme -ne 'https' -or $resolved.Host -ne 'api.fabric.microsoft.com' -or
            -not $resolved.IsDefaultPort -or $resolved.UserInfo -or $resolved.Fragment -or
            $resolved.AbsolutePath -cne ([uri]$statusUri).AbsolutePath) {
            throw 'Fabric returned an unexpected table-status continuation URL.'
        }
        if (-not $seen.Add($resolved.AbsoluteUri) -or $seen.Count -gt 100) {
            throw 'Fabric returned a repeated or excessive table-status continuation.'
        }
        $page = Invoke-RestMethod -Method Post -Uri $resolved.AbsoluteUri -Headers $Headers `
            -ContentType 'application/json' -Body '{}'
        if (-not $page.PSObject.Properties['data'] -or $page.data -isnot [array]) {
            throw 'Fabric returned a table-status page without a data array.'
        }
        $statuses += @($page.data)
        if ($page.PSObject.Properties['continuationUri'] -and $page.continuationUri) {
            $next = $page.continuationUri
        } elseif ($page.PSObject.Properties['continuationToken'] -and $page.continuationToken) {
            $token = [Uri]::EscapeDataString([string]$page.continuationToken)
            $next = "$statusUri`?continuationToken=$token"
        } else {
            $next = $null
        }
    }
    if ($statuses.Count -ne $Tables.Count) {
        throw 'Fabric did not return exactly the two expected PostgreSQL table statuses.'
    }
    foreach ($table in $Tables) {
        $matches = @($statuses | Where-Object {
            $_.sourceObjectType -ceq 'Table' -and $_.sourceSchemaName -ceq 'public' -and
            $_.sourceTableName -ceq $table.name
        })
        if ($matches.Count -ne 1 -or $matches[0].status -cne 'Replicating' -or
            ($matches[0].PSObject.Properties['error'] -and $matches[0].error) -or
            -not $matches[0].PSObject.Properties['metrics'] -or -not $matches[0].metrics -or
            -not $matches[0].metrics.PSObject.Properties['lastSyncDateTime'] -or
            -not (Test-MirrorSyncTimestamp -Value $matches[0].metrics.lastSyncDateTime)) {
            throw "The PostgreSQL mirror table '$($table.name)' is not replicating with a valid sync timestamp."
        }
    }
    Write-Host 'The mirror and both facilities tables report replication; row equality and freshness remain unverified.'
}
