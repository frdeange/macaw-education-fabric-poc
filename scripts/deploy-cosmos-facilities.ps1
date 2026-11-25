[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$WorkspaceId,

    [string]$DatabaseName = 'MacawFacilitiesIncidents',
    [string]$SkillAttribution = 'e2e-medallion-architecture',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($DatabaseName) -or
    [string]::IsNullOrWhiteSpace($SkillAttribution)) {
    throw 'Database name and Fabric skill attribution must not be empty.'
}

$definitionPath = Join-Path $PSScriptRoot '..\fabric\cosmos-facilities-definition.json'
$definition = Get-Content -LiteralPath $definitionPath -Raw
$contract = $definition | ConvertFrom-Json
if (@($contract.containers).Count -ne 1 -or
    $contract.containers[0].resource.id -cne 'FacilityIncidents' -or
    @($contract.containers[0].resource.partitionKey.paths).Count -ne 1 -or
    $contract.containers[0].resource.partitionKey.paths[0] -cne '/campusKey' -or
    $contract.containers[0].options.autoscaleSettings.maxThroughput -ne 1000) {
    throw 'The Cosmos facilities container definition does not match the reviewed contract.'
}

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$headers['x-ms-fabric-skill'] = $SkillAttribution
$api = 'https://api.fabric.microsoft.com/v1'
$base = "$api/workspaces/$WorkspaceId"
$description = 'Macaw education PoC synthetic facilities incidents.'

try {
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

    $databases = @(Get-FabricItems -Uri "$base/cosmosDbDatabases" -Headers $headers |
        Where-Object { $_.displayName -ceq $DatabaseName })
    if ($databases.Count -gt 1) {
        throw 'Multiple Cosmos databases have the requested name; inspect them before proceeding.'
    }
    if ($databases.Count -eq 0) {
        if ($VerifyOnly) {
            throw 'The Cosmos facilities database was not found.'
        }
        $body = @{
            displayName = $DatabaseName
            description = $description
            definition = @{
                parts = @(@{
                    path = 'definition.json'
                    payloadType = 'InlineBase64'
                    payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($definition))
                })
            }
        } | ConvertTo-Json -Depth 10 -Compress
        $response = Invoke-WebRequest -Method Post -Uri "$base/cosmosDbDatabases" `
            -Headers $headers -ContentType 'application/json' -Body $body -SkipHttpErrorCheck
        if ($response.StatusCode -eq 202) {
            Wait-FabricOperation -Response $response -Headers $headers
        } elseif ($response.StatusCode -ne 201) {
            throw "Cosmos database creation failed: HTTP $($response.StatusCode): $($response.Content)"
        }
        $databases = @(Get-FabricItems -Uri "$base/cosmosDbDatabases" -Headers $headers |
            Where-Object { $_.displayName -ceq $DatabaseName })
    }
    if ($databases.Count -ne 1 -or $databases[0].description -cne $description) {
        throw 'The Cosmos facilities database was not uniquely found with the project description.'
    }
    $database = Invoke-RestMethod -Uri "$base/cosmosDbDatabases/$($databases[0].id)" -Headers $headers
    if ($database.workspaceId -ne $WorkspaceId.ToString() -or
        $database.properties.databaseName -cne $DatabaseName -or
        [string]::IsNullOrWhiteSpace($database.properties.serverFqdn)) {
        throw 'The Cosmos facilities database connection metadata is incomplete or unexpected.'
    }
    Write-Host "Verified Cosmos database '$DatabaseName' in the selected workspace."
    Write-Host 'Container settings and data must be checked separately. No consumer access was granted.'
} finally {
    $headers.Clear()
}
