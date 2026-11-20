[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$WorkspaceId,

    [Parameter(Mandatory)]
    [guid]$SemanticModelId,

    [Parameter(Mandatory)]
    [string]$BaselineDefinitionPath,

    [Parameter(Mandatory)]
    [string[]]$PartPaths
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\semantic-model')).Path
Assert-SemanticModelDeploymentAllowed -ModelRoot $root
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$base = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId"
$matches = @(Get-FabricItems -Uri "$base/semanticModels" -Headers $headers |
    Where-Object { $_.id -eq $SemanticModelId.ToString() })
if ($matches.Count -ne 1) {
    throw 'The semantic model was not uniquely found in the target workspace.'
}

$baseline = Get-Content -LiteralPath $BaselineDefinitionPath -Raw | ConvertFrom-Json
$response = Invoke-WebRequest -Method Post `
    -Uri "$base/semanticModels/$SemanticModelId/getDefinition?format=TMDL" `
    -Headers $headers -ContentType 'application/json' -Body '{}'
if ($response.StatusCode -eq 202) {
    Wait-FabricOperation -Response $response -Headers $headers
    $operationId = [string]@($response.Headers['x-ms-operation-id'])[0]
    $current = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId/result" `
        -Headers $headers
} elseif ($response.StatusCode -eq 200) {
    $current = $response.Content | ConvertFrom-Json
} else {
    throw "Unexpected semantic-model definition status: $($response.StatusCode)."
}

$baselineParts = @{}
foreach ($part in $baseline.definition.parts | Where-Object { $_.path -ne '.platform' }) {
    if ($baselineParts.ContainsKey($part.path)) {
        throw "The baseline contains a duplicate part: $($part.path)."
    }
    $baselineParts[$part.path] = $part
}
$currentParts = @{}
foreach ($part in $current.definition.parts | Where-Object { $_.path -ne '.platform' }) {
    if ($currentParts.ContainsKey($part.path)) {
        throw "The published definition contains a duplicate part: $($part.path)."
    }
    $currentParts[$part.path] = $part
}
if ($currentParts.Count -ne $baselineParts.Count) {
    throw 'The published model has changed since the baseline was captured; inspect it before updating.'
}
foreach ($path in $baselineParts.Keys) {
    if (-not $currentParts.ContainsKey($path) -or
        $baselineParts[$path].payload -cne $currentParts[$path].payload -or
        $baselineParts[$path].payloadType -cne $currentParts[$path].payloadType) {
        throw "The published model has changed since the baseline was captured: $path."
    }
}

$rootPrefix = $root.TrimEnd('\') + '\'
foreach ($path in $PartPaths) {
    if ($path -notmatch '^definition/(?:[^/]+/)*[^/]+\.tmdl$' -or
        $path -match '(^|/)\.\.?(/|$)') {
        throw "Invalid semantic-model part path: $path."
    }
    $filePath = [IO.Path]::GetFullPath((Join-Path $root ($path.Replace('/', '\'))))
    if (-not $filePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "Semantic-model part not found under the definition root: $path."
    }
    $content = [IO.File]::ReadAllText($filePath)
    if (-not $content.Trim() -or $content -match '__[A-Z_]+__') {
        throw "Semantic-model part is empty or contains an unresolved placeholder: $path."
    }
    $currentParts[$path] = @{
        path = $path
        payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        payloadType = 'InlineBase64'
    }
}

$parts = @($currentParts.Keys | Sort-Object | ForEach-Object { $currentParts[$_] })
$body = @{ definition = @{ format = 'TMDL'; parts = $parts } } |
    ConvertTo-Json -Depth 20 -Compress
$response = Invoke-WebRequest -Method Post `
    -Uri "$base/semanticModels/$SemanticModelId/updateDefinition" `
    -Headers $headers -ContentType 'application/json' -Body $body
if ($response.StatusCode -eq 202) {
    Wait-FabricOperation -Response $response -Headers $headers
} elseif ($response.StatusCode -ne 200) {
    throw "Unexpected semantic-model update status: $($response.StatusCode)."
}

Write-Host "Updated semantic model $SemanticModelId; validate and refresh it before use."
