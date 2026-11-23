[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$WorkspaceId,

    [string]$BronzeName = 'MacawEducationBronze',
    [string]$SilverName = 'MacawEducationSilver',
    [string]$GoldName = 'MacawEducationGold',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$targets = @(
    @{ Name = $BronzeName; Description = 'Macaw education PoC Bronze lakehouse.' }
    @{ Name = $SilverName; Description = 'Macaw education PoC Silver lakehouse.' }
    @{ Name = $GoldName; Description = 'Macaw education PoC Gold lakehouse.' }
)
if (@($targets | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) }).Count -gt 0 -or
    @($targets.Name | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
    throw 'Lakehouse names must be nonempty and distinct.'
}

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$headers['x-ms-fabric-skill'] = 'e2e-medallion-architecture'
$api = 'https://api.fabric.microsoft.com/v1'
$base = "$api/workspaces/$WorkspaceId"

$workspaces = @(Get-FabricItems -Uri "$api/workspaces" -Headers $headers |
    Where-Object { $_.id -eq $WorkspaceId.ToString() })
if ($workspaces.Count -ne 1 -or
    -not $workspaces[0].PSObject.Properties['capacityId'] -or
    -not $workspaces[0].capacityId) {
    throw 'The target workspace was not uniquely found on a Fabric capacity.'
}
$capacities = @(Get-FabricItems -Uri "$api/capacities" -Headers $headers |
    Where-Object { $_.id -eq $workspaces[0].capacityId })
if ($capacities.Count -ne 1 -or $capacities[0].state -ne 'Active') {
    throw 'The workspace capacity is not uniquely visible and active.'
}

function Assert-LakehouseReady {
    param($Item, $Target)

    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $lakehouse = Invoke-RestMethod -Uri "$base/lakehouses/$($Item.id)" -Headers $headers
        if ($lakehouse.id -ne $Item.id -or $lakehouse.workspaceId -ne $WorkspaceId.ToString() -or
            $lakehouse.type -ne 'Lakehouse' -or $lakehouse.displayName -ne $Target.Name -or
            $lakehouse.description -ne $Target.Description) {
            throw "Lakehouse '$($Target.Name)' does not match the expected project item; inspect it."
        }

        $properties = $lakehouse.PSObject.Properties['properties']
        $endpoint = if ($properties -and $properties.Value) {
            $properties.Value.PSObject.Properties['sqlEndpointProperties']
        }
        $status = if ($endpoint -and $endpoint.Value) {
            $endpoint.Value.PSObject.Properties['provisioningStatus']
        }
        if ($status -and $status.Value -eq 'Failed') {
            throw "The SQL endpoint for '$($Target.Name)' failed to provision."
        }
        if ($status -and $status.Value -eq 'Success') {
            $schema = $properties.Value.PSObject.Properties['defaultSchema']
            if (-not $schema -or $schema.Value -ne 'dbo') {
                throw "Lakehouse '$($Target.Name)' is not schema-enabled with the expected default schema."
            }
            if (-not $properties.Value.oneLakeFilesPath -or -not $properties.Value.oneLakeTablesPath -or
                -not $endpoint.Value.id -or -not $endpoint.Value.connectionString) {
                throw "Lakehouse '$($Target.Name)' has incomplete OneLake or SQL endpoint properties."
            }
            Write-Host "Verified '$($Target.Name)': schemas enabled; SQL endpoint ready."
            return [string]$endpoint.Value.id
        }
        if ($attempt -lt 29) { Start-Sleep -Seconds 10 }
    }
    throw "The SQL endpoint for '$($Target.Name)' is not ready; inspect it before rerunning."
}

$items = @(Get-FabricItems -Uri "$base/items" -Headers $headers)
$missing = @()
foreach ($target in $targets) {
    $matches = @($items | Where-Object { $_.displayName -eq $target.Name })
    $lakehouses = @($matches | Where-Object { $_.type -eq 'Lakehouse' })
    if ($lakehouses.Count -gt 1 -or ($lakehouses.Count -eq 0 -and $matches.Count -gt 0)) {
        throw "The name '$($target.Name)' is ambiguous or belongs to another item type; inspect it."
    }
    if ($lakehouses.Count -eq 0) {
        $missing += $target
    } else {
        $endpointId = Assert-LakehouseReady -Item $lakehouses[0] -Target $target
        $otherItems = @($matches | Where-Object {
            $_.type -ne 'Lakehouse' -and ($_.type -ne 'SQLEndpoint' -or $_.id -ne $endpointId)
        })
        if ($otherItems.Count -gt 0) {
            throw "The name '$($target.Name)' is also used by an unrelated item; inspect it."
        }
    }
}
if ($VerifyOnly -and $missing.Count -gt 0) {
    throw "Lakehouses missing in verify-only mode: $(($missing.Name) -join ', ')."
}

foreach ($target in $missing) {
    $body = @{
        displayName = $target.Name
        description = $target.Description
        creationPayload = @{ enableSchemas = $true }
    } | ConvertTo-Json -Depth 4 -Compress
    $response = Invoke-WebRequest -Method Post -Uri "$base/lakehouses" `
        -Headers $headers -ContentType 'application/json' -Body $body
    if ($response.StatusCode -eq 202) {
        Wait-FabricOperation -Response $response -Headers $headers
    } elseif ($response.StatusCode -ne 201) {
        throw "Unexpected creation status for '$($target.Name)': $($response.StatusCode). Inspect before retrying."
    }

    $created = @()
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $created = @(Get-FabricItems -Uri "$base/lakehouses" -Headers $headers |
            Where-Object { $_.displayName -eq $target.Name })
        if ($created.Count -gt 1) {
            throw "Created lakehouse '$($target.Name)' is ambiguous; inspect it before rerunning."
        }
        if ($created.Count -eq 1) { break }
        if ($attempt -lt 11) { Start-Sleep -Seconds 5 }
    }
    if ($created.Count -ne 1) {
        throw "Creation of '$($target.Name)' completed but the item was not found; inspect before rerunning."
    }
    $null = Assert-LakehouseReady -Item $created[0] -Target $target
}

Write-Host 'Lakehouse foundation verified. No data was ingested or permissions explicitly granted.'
