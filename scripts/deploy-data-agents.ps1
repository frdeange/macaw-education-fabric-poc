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

    [switch]$UpdateExisting
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\fabric\data-agents.json') -Raw | ConvertFrom-Json
$base = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId"

$models = @(Get-FabricItems -Uri "$base/semanticModels" -Headers $headers)
if (@($models | Where-Object { $_.id -eq $SemanticModelId.ToString() }).Count -ne 1) {
    throw 'The semantic model was not uniquely found in the target workspace.'
}

$existing = @(Get-FabricItems -Uri "$base/dataAgents" -Headers $headers)
foreach ($agent in $config.agents) {
    $agentMatches = @($existing | Where-Object { $_.displayName -eq $agent.name })
    if (-not $UpdateExisting -and $agentMatches.Count -ne 0) {
        throw "A data agent named '$($agent.name)' already exists; inspect it before deploying."
    }
    if ($UpdateExisting) {
        if ($agentMatches.Count -ne 1) {
            throw "Data agent '$($agent.name)' was not uniquely found for update."
        }
        $sources = @(Get-FabricItems -Uri "$base/dataAgents/$($agentMatches[0].id)/staging/datasources" -Headers $headers)
        if ($sources.Count -ne 1 -or $sources[0].fabricItemType -ne 'SemanticModel' -or
            $sources[0].itemReference.itemId -ne $SemanticModelId.ToString()) {
            throw "The existing data source does not match '$($agent.name)'; inspect it before updating."
        }
    }
}

foreach ($agent in $config.agents) {
    if ($UpdateExisting) {
        $created = @($existing | Where-Object { $_.displayName -eq $agent.name })
    } else {
        $createBody = @{ displayName = $agent.name; description = $agent.description } |
            ConvertTo-Json -Compress
        $response = Invoke-WebRequest -Method Post -Uri "$base/dataAgents" `
            -Headers $headers -ContentType 'application/json' -Body $createBody
        if ($response.StatusCode -eq 202) {
            Wait-FabricOperation -Response $response -Headers $headers
        } elseif ($response.StatusCode -ne 201) {
            throw "Unexpected data-agent creation status: $($response.StatusCode)."
        }
        $created = @(Get-FabricItems -Uri "$base/dataAgents" -Headers $headers |
            Where-Object { $_.displayName -eq $agent.name })
        if ($created.Count -ne 1) {
            throw "The created data agent '$($agent.name)' could not be uniquely resolved."
        }
        Write-Host "Created $($agent.name): $($created[0].id)"
    }
    $agentBase = "$base/dataAgents/$($created[0].id)"

    $instructions = $agent.instructions -join "`n"
    $settingsBody = @{ aiInstructions = $instructions } | ConvertTo-Json -Compress
    $settings = Invoke-RestMethod -Method Patch -Uri "$agentBase/staging/settings" `
        -Headers $headers -ContentType 'application/json' -Body $settingsBody
    if ($settings.aiInstructions -ne $instructions) {
        throw "Staging instructions do not match for '$($agent.name)'."
    }

    if (-not $UpdateExisting) {
        $sourceBody = @{
            type = 'FabricItem'
            itemReference = @{
                referenceType = 'ById'
                itemId = $SemanticModelId.ToString()
                workspaceId = $WorkspaceId.ToString()
            }
        } | ConvertTo-Json -Depth 10 -Compress
        $response = Invoke-WebRequest -Method Post -Uri "$agentBase/staging/datasources" `
            -Headers $headers -ContentType 'application/json' -Body $sourceBody
        if ($response.StatusCode -eq 202) {
            Wait-FabricOperation -Response $response -Headers $headers
        } elseif ($response.StatusCode -ne 201) {
            throw "Unexpected data-source creation status: $($response.StatusCode)."
        }
    }

    $sources = @(Get-FabricItems -Uri "$agentBase/staging/datasources" -Headers $headers)
    if ($sources.Count -ne 1 -or $sources[0].fabricItemType -ne 'SemanticModel' -or
        $sources[0].itemReference.itemId -ne $SemanticModelId.ToString()) {
        throw "The staged data source is not the expected semantic model for '$($agent.name)'."
    }

    $elementsUri = "$agentBase/staging/datasources/$($sources[0].id)/elements"
    $elements = @(Get-FabricItems -Uri $elementsUri -Headers $headers)
    foreach ($tableName in $agent.tables) {
        $table = @($elements | Where-Object { $_.type -eq 'Table' -and $_.displayName -eq $tableName })
        if ($table.Count -ne 1 -or $table[0].state -ne 'Available') {
            throw "Table '$tableName' is not uniquely available for '$($agent.name)'."
        }
    }
    $unexpected = @($elements | Where-Object { $_.type -eq 'Table' -and $_.isSelected -and $_.displayName -notin $agent.tables })
    if ($unexpected.Count -ne 0) {
        throw "Unexpected selected tables exist for '$($agent.name)'; inspect them before updating."
    }
    foreach ($table in @($elements | Where-Object { $_.type -eq 'Table' -and $_.displayName -in $agent.tables })) {
        $partialSelection = $table.PSObject.Properties.Name -contains 'selectionState' -and
            $table.selectionState -ne 'Selected'
        if (-not $table.isSelected -or $partialSelection) {
            $elementId = [Uri]::EscapeDataString($table.id)
            $updated = Invoke-RestMethod -Method Patch -Uri "$elementsUri`?id=$elementId" `
                -Headers $headers -ContentType 'application/json' -Body '{"isSelected":true}'
            if (-not $updated.isSelected) {
                throw "Table '$($table.displayName)' was not selected for '$($agent.name)'."
            }
        }
    }

    $publishBody = @{ publishedDescription = $agent.description } | ConvertTo-Json -Compress
    $published = Invoke-RestMethod -Method Post -Uri "$agentBase/staging/publish" `
        -Headers $headers -ContentType 'application/json' -Body $publishBody
    if ($published.publishedDescription -ne $agent.description) {
        throw "Published description does not match for '$($agent.name)'."
    }
    $publishedSettings = Invoke-RestMethod -Uri "$agentBase/settings" -Headers $headers
    $publishedSources = @(Get-FabricItems -Uri "$agentBase/datasources" -Headers $headers)
    if ($publishedSettings.aiInstructions -ne $instructions -or $publishedSources.Count -ne 1 -or
        $publishedSources[0].itemReference.itemId -ne $SemanticModelId.ToString()) {
        throw "Published settings or data source do not match for '$($agent.name)'."
    }
    $publishedElements = @(Get-FabricItems -Uri "$agentBase/datasources/$($publishedSources[0].id)/elements" -Headers $headers)
    $selectedTables = @($publishedElements | Where-Object { $_.type -eq 'Table' -and $_.isSelected })
    if ($selectedTables.Count -ne $agent.tables.Count -or
        @($selectedTables | Where-Object { $_.displayName -notin $agent.tables }).Count -ne 0) {
        throw "Published table selection does not match for '$($agent.name)'."
    }
    foreach ($table in $selectedTables) {
        $elementId = [Uri]::EscapeDataString($table.id)
        $children = @(Get-FabricItems -Uri "$agentBase/datasources/$($publishedSources[0].id)/elements?rootId=$elementId" -Headers $headers)
        if ($children.Count -eq 0 -or @($children | Where-Object { -not $_.isSelected }).Count -ne 0) {
            throw "Published elements are not fully selected for table '$($table.displayName)' in '$($agent.name)'."
        }
    }
    Write-Host "Published $($agent.name); access has not been shared."
}
