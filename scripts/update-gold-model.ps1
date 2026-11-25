[CmdletBinding()]
param(
    [Parameter(Mandatory)][guid]$SubscriptionId,
    [Parameter(Mandatory)][guid]$TenantId,
    [Parameter(Mandatory)][guid]$WorkspaceId,
    [Parameter(Mandatory)][guid]$SemanticModelId,
    [Parameter(Mandatory)][ValidateSet('operations', 'outcomes')][string]$Domain,
    [Parameter(Mandatory)][string]$BaselineDefinitionPath,
    [switch]$OutcomesMetadataOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($OutcomesMetadataOnly -and $Domain -ne 'outcomes') {
    throw 'The metadata-only correction applies only to the Outcomes model.'
}
. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$base = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId"
$names = @{ operations = 'Macaw Gold School Operations'; outcomes = 'Macaw Gold Learning Outcomes' }
$model = @(Get-FabricItems -Uri "$base/semanticModels" -Headers $headers |
    Where-Object { $_.id -eq $SemanticModelId.ToString() -and $_.displayName -ceq $names[$Domain] })
$lakehouse = @(Get-FabricItems -Uri "$base/lakehouses" -Headers $headers |
    Where-Object { $_.displayName -ceq 'MacawEducationGold' })
if ($model.Count -ne 1 -or $lakehouse.Count -ne 1) {
    throw 'The target model or Gold Lakehouse was not uniquely identified.'
}

$baseline = Get-Content -LiteralPath $BaselineDefinitionPath -Raw | ConvertFrom-Json
$response = Invoke-WebRequest -Method Post `
    -Uri "$base/semanticModels/$SemanticModelId/getDefinition?format=TMDL" `
    -Headers $headers -ContentType 'application/json' -Body '{}'
if ($response.StatusCode -eq 202) {
    Wait-FabricOperation -Response $response -Headers $headers
    $operationId = [string]@($response.Headers['x-ms-operation-id'])[0]
    $current = Invoke-RestMethod -Uri "https://api.fabric.microsoft.com/v1/operations/$operationId/result" -Headers $headers
} elseif ($response.StatusCode -eq 200) {
    $current = $response.Content | ConvertFrom-Json
} else {
    throw "Unexpected definition status: $($response.StatusCode)."
}

$currentParts = @{}
$baselineParts = @{}
foreach ($part in $current.definition.parts | Where-Object { $_.path -ne '.platform' }) {
    if ($currentParts.ContainsKey($part.path)) { throw "Duplicate current part: $($part.path)." }
    $currentParts[$part.path] = $part
}
foreach ($part in $baseline.definition.parts | Where-Object { $_.path -ne '.platform' }) {
    if ($baselineParts.ContainsKey($part.path)) { throw "Duplicate baseline part: $($part.path)." }
    $baselineParts[$part.path] = $part
}
if ($currentParts.Count -ne $baselineParts.Count) {
    throw 'The model definition changed since the baseline was captured.'
}
foreach ($path in $baselineParts.Keys) {
    if (-not $currentParts.ContainsKey($path) -or
        $baselineParts[$path].payload -cne $currentParts[$path].payload -or
        $baselineParts[$path].payloadType -cne $currentParts[$path].payloadType) {
        throw "The model definition changed since the baseline was captured: $path."
    }
}

if ($OutcomesMetadataOnly) {
    $currentJson = ConvertTo-Json -InputObject @($currentParts.Values) -Depth 30 -Compress
    $patchedJson = $currentJson | & python (Join-Path $PSScriptRoot 'patch_gold_outcomes_metadata.py')
    if ($LASTEXITCODE -ne 0) { throw 'The Outcomes metadata correction failed.' }
    $parts = @($patchedJson | ConvertFrom-Json)
} else {
    $generated = & python (Join-Path $PSScriptRoot 'gold_model_definitions.py') `
        $WorkspaceId.ToString() $lakehouse[0].id $Domain
    if ($LASTEXITCODE -ne 0) { throw 'Model definition generation failed.' }
    $generatedParts = @{}
    foreach ($part in ($generated | ConvertFrom-Json)) { $generatedParts[$part.path] = $part }
    $facts = if ($Domain -eq 'operations') {
        @('Enrollment', 'Subject Enrollment', 'Attendance', 'Planned Timetable',
          'Facility Incidents', 'Planned Closure Impacts')
    } else {
        @('Assessment Results')
    }
    $replace = @('definition/model.tmdl', 'definition/relationships.tmdl') +
        @($facts | ForEach-Object { "definition/tables/$_.tmdl" })
    $oldModel = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($currentParts['definition/model.tmdl'].payload))
    $newModel = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($generatedParts['definition/model.tmdl'].payload))
    foreach ($line in ($oldModel -split '\r?\n')) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^ref table (.+)$') {
            $tableName = $Matches[1].Trim("'")
            if ($newModel -notmatch "(?m)^ref table '$([regex]::Escape($tableName))'\s*$") {
                throw "Existing table reference would be lost: $tableName."
            }
        } elseif ($trimmed -and $trimmed -notin @('model Model', 'culture: en-US',
                 'defaultPowerBIDataSourceVersion: powerBI_V3')) {
            throw "Unexpected model metadata must be preserved manually: $trimmed."
        }
    }
    foreach ($path in $replace) {
        if (-not $currentParts.ContainsKey($path) -or -not $generatedParts.ContainsKey($path)) {
            throw "Expected definition part missing: $path."
        }
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($currentParts[$path].payload))
        if ($path -ne 'definition/model.tmdl') {
            foreach ($line in ($text -split '\r?\n')) {
                $trimmed = $line.Trim()
                if ($trimmed -and $trimmed -notmatch '^(///|table |measure |column |partition |relationship |dataType: |formatString: |isHidden$|summarizeBy: |sourceColumn: |mode: |source$|entityName: |schemaName: |expressionSource: |fromColumn: |toColumn: )') {
                    throw "Existing metadata needs manual preservation in $path`: $trimmed."
                }
            }
        }
        $currentParts[$path] = $generatedParts[$path]
    }
    foreach ($name in @('Class Section', 'Date')) {
        $path = "definition/tables/$name.tmdl"
        if ($generatedParts.ContainsKey($path) -and -not $currentParts.ContainsKey($path)) {
            $currentParts[$path] = $generatedParts[$path]
        }
    }
    $parts = @($currentParts.Keys | Sort-Object | ForEach-Object { $currentParts[$_] })
}
$body = @{ definition = @{ format = 'TMDL'; parts = $parts } } | ConvertTo-Json -Depth 30 -Compress
$response = Invoke-WebRequest -Method Post -Uri "$base/semanticModels/$SemanticModelId/updateDefinition" `
    -Headers $headers -ContentType 'application/json' -Body $body
if ($response.StatusCode -eq 202) {
    Wait-FabricOperation -Response $response -Headers $headers
} elseif ($response.StatusCode -ne 200) {
    throw "Unexpected definition update status: $($response.StatusCode)."
}
Write-Output "Updated $($names[$Domain]); refresh and validate before use."
