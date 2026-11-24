[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$WorkspaceId
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$base = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId"
$lakehouses = @(Get-FabricItems -Uri "$base/lakehouses" -Headers $headers |
    Where-Object { $_.displayName -ceq 'MacawEducationGold' })
if ($lakehouses.Count -ne 1 -or $lakehouses[0].properties.sqlEndpointProperties.provisioningStatus -ne 'Success') {
    throw 'The Gold Lakehouse or its SQL endpoint is not uniquely ready.'
}
$models = @(
    @{ Domain = 'operations'; Name = 'Macaw Gold School Operations' },
    @{ Domain = 'outcomes'; Name = 'Macaw Gold Learning Outcomes' }
)
$existing = @(Get-FabricItems -Uri "$base/semanticModels" -Headers $headers)
foreach ($model in $models) {
    if (@($existing | Where-Object { $_.displayName -ceq $model.Name }).Count -ne 0) {
        throw "Model '$($model.Name)' already exists; inspect it before deploying."
    }
}
foreach ($model in $models) {
    $generated = & python (Join-Path $PSScriptRoot 'gold_model_definitions.py') `
        $WorkspaceId.ToString() $lakehouses[0].id $model.Domain
    if ($LASTEXITCODE -ne 0) { throw "Definition generation failed for $($model.Name)." }
    $parts = $generated | ConvertFrom-Json
    $body = @{
        displayName = $model.Name
        description = 'Synthetic Dutch education Gold model for administrator-only proof-of-concept testing.'
        definition = @{ format = 'TMDL'; parts = @($parts) }
    } | ConvertTo-Json -Depth 30 -Compress
    $response = Invoke-WebRequest -Method Post -Uri "$base/semanticModels" `
        -Headers $headers -ContentType 'application/json' -Body $body
    if ($response.StatusCode -eq 202) {
        Wait-FabricOperation -Response $response -Headers $headers
    } elseif ($response.StatusCode -ne 201) {
        throw "Unexpected model creation status: $($response.StatusCode)."
    }
    $created = @(Get-FabricItems -Uri "$base/semanticModels" -Headers $headers |
        Where-Object { $_.displayName -ceq $model.Name })
    if ($created.Count -ne 1) { throw "Could not uniquely resolve $($model.Name) after creation." }
    Write-Output "Created $($model.Name)."
}
