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

    [string]$DisplayName = 'Macaw Education'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId

$base = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId"
$databases = @(Get-FabricItems -Uri "$base/sqlDatabases" -Headers $headers)
if (@($databases | Where-Object { $_.id -eq $DatabaseItemId.ToString() }).Count -ne 1) {
    throw 'The SQL database item was not uniquely found in the target workspace.'
}

$models = @(Get-FabricItems -Uri "$base/semanticModels" -Headers $headers)
if (@($models | Where-Object { $_.displayName -eq $DisplayName }).Count -ne 0) {
    throw "A semantic model named '$DisplayName' already exists; inspect it before deploying."
}

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\semantic-model')).Path
$files = @(Get-ChildItem -LiteralPath $root -File -Recurse |
    Where-Object { $_.Extension -in @('.tmdl', '.pbism') } |
    Sort-Object FullName)
if ($files.Count -eq 0) {
    throw 'No semantic-model definition files were found.'
}

$parts = foreach ($file in $files) {
    $path = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
    $content = [IO.File]::ReadAllText($file.FullName)
    $content = $content.Replace('__WORKSPACE_ID__', $WorkspaceId.ToString())
    $content = $content.Replace('__DATABASE_ITEM_ID__', $DatabaseItemId.ToString())
    if ($content -match '__[A-Z_]+__') {
        throw "Unresolved placeholder in $path."
    }
    @{
        path = $path
        payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
        payloadType = 'InlineBase64'
    }
}

$body = @{
    displayName = $DisplayName
    description = 'Synthetic Dutch education, attendance and learning outcomes.'
    definition = @{ format = 'TMDL'; parts = @($parts) }
} | ConvertTo-Json -Depth 20 -Compress

$response = Invoke-WebRequest -Method Post -Uri "$base/semanticModels" `
    -Headers $headers -ContentType 'application/json' -Body $body

if ($response.StatusCode -eq 202) {
    Wait-FabricOperation -Response $response -Headers $headers
} elseif ($response.StatusCode -ne 201) {
    throw "Unexpected semantic-model creation status: $($response.StatusCode)."
}

$created = @(Get-FabricItems -Uri "$base/semanticModels" -Headers $headers |
    Where-Object { $_.displayName -eq $DisplayName })
if ($created.Count -ne 1) {
    throw 'Creation completed but the semantic model could not be uniquely resolved.'
}

$created[0] | Select-Object id, displayName, type, workspaceId
