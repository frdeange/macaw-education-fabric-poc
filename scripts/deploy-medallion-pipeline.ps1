[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$WorkspaceId,

    [string]$BronzeToSilverNotebookName = 'Macaw Bronze to Silver',
    [string]$SilverToGoldNotebookName = 'Macaw Silver to Gold',
    [string]$PipelineName = 'Macaw Education Medallion',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$notebookNames = @($BronzeToSilverNotebookName, $SilverToGoldNotebookName)
if ($notebookNames | Where-Object { [string]::IsNullOrWhiteSpace($_) }) {
    throw 'Notebook names must not be empty.'
}
if (@($notebookNames | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
    throw 'Notebook names must be distinct.'
}
if ([string]::IsNullOrWhiteSpace($PipelineName)) {
    throw 'Pipeline name must not be empty.'
}

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$headers['x-ms-fabric-skill'] = 'e2e-medallion-architecture'
$api = 'https://api.fabric.microsoft.com/v1'
$base = "$api/workspaces/$WorkspaceId"
$pipelineDescription = 'Sequential SQL-mirror Silver and Gold transformations for the verified education snapshot.'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$definitionPath = Join-Path $repoRoot 'fabric\medallion-pipeline-content.json'
$expectedNotebookDescriptions = @{
    $BronzeToSilverNotebookName = 'Macaw education Bronze-to-Silver validation and conformed Delta products.'
    $SilverToGoldNotebookName = 'Macaw education Silver-to-Gold agent-ready Delta products.'
}

try {
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

    $items = @(Get-FabricItems -Uri "$base/items" -Headers $headers)
    foreach ($notebookName in $notebookNames) {
        $notebookMatches = @($items | Where-Object { $_.displayName -ceq $notebookName })
        if ($notebookMatches.Count -ne 1 -or
            $notebookMatches[0].type -ne 'Notebook' -or
            $notebookMatches[0].description -cne $expectedNotebookDescriptions[$notebookName]) {
            throw "Notebook '$notebookName' is missing, ambiguous, or not the expected project item."
        }
    }

    $sameName = @($items | Where-Object { $_.displayName -ceq $PipelineName })
    $pipelines = @($sameName | Where-Object { $_.type -eq 'DataPipeline' })
    if ($sameName.Count -gt 1 -or ($sameName.Count -eq 1 -and $pipelines.Count -ne 1)) {
        throw "The name '$PipelineName' is ambiguous or belongs to another item type."
    }
    if ($pipelines.Count -eq 1 -and $pipelines[0].description -cne $pipelineDescription) {
        throw "Existing pipeline '$PipelineName' is not the expected project item; inspect it."
    }
    if ($VerifyOnly) {
        if ($pipelines.Count -ne 1) {
            throw "Pipeline '$PipelineName' is missing in verify-only mode."
        }
        Write-Host "Pipeline item and both prerequisite notebooks are present: $PipelineName."
        return
    }
    if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
        throw "Pipeline definition not found: $definitionPath"
    }

    $items = @(Get-FabricItems -Uri "$base/items" -Headers $headers)
    $bronzeNotebook = @($items | Where-Object {
        $_.type -eq 'Notebook' -and $_.displayName -ceq $BronzeToSilverNotebookName
    })
    $goldNotebook = @($items | Where-Object {
        $_.type -eq 'Notebook' -and $_.displayName -ceq $SilverToGoldNotebookName
    })
    if ($bronzeNotebook.Count -ne 1 -or $goldNotebook.Count -ne 1) {
        throw 'Notebook items changed while preparing the pipeline; inspect before retrying.'
    }

    $definitionContent = Get-Content -LiteralPath $definitionPath -Raw |
        ConvertFrom-Json -AsHashtable
    $activities = $definitionContent.properties.activities
    $activities | Where-Object { $_.name -eq 'BronzeToSilver' } |
        ForEach-Object { $_.typeProperties.notebookId = $bronzeNotebook[0].id }
    $activities | Where-Object { $_.name -eq 'SilverToGold' } |
        ForEach-Object { $_.typeProperties.notebookId = $goldNotebook[0].id }
    foreach ($activity in $activities) {
        if ($activity.type -eq 'TridentNotebook') {
            $activity.typeProperties.workspaceId = $WorkspaceId.ToString()
        }
    }
    $pipelineJson = $definitionContent | ConvertTo-Json -Depth 40
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pipelineJson))
    $definition = @{
        parts = @(@{
            path = 'pipeline-content.json'
            payload = $payload
            payloadType = 'InlineBase64'
        })
    }

    if ($pipelines.Count -eq 0) {
        $createBody = @{
            displayName = $PipelineName
            description = $pipelineDescription
            definition = $definition
        } | ConvertTo-Json -Depth 12 -Compress
        $response = Invoke-WebRequest -Method Post -Uri "$base/dataPipelines" `
            -Headers $headers -ContentType 'application/json' -Body $createBody
        if ($response.StatusCode -eq 202) {
            Wait-FabricOperation -Response $response -Headers $headers
        } elseif ($response.StatusCode -ne 201) {
            throw "Unexpected pipeline creation status: $($response.StatusCode)."
        }
        $operation = 'created'
    } else {
        $updateBody = @{ definition = $definition } | ConvertTo-Json -Depth 12 -Compress
        $response = Invoke-WebRequest -Method Post `
            -Uri "$base/dataPipelines/$($pipelines[0].id)/updateDefinition" `
            -Headers $headers -ContentType 'application/json' -Body $updateBody
        if ($response.StatusCode -eq 202) {
            Wait-FabricOperation -Response $response -Headers $headers
        } elseif ($response.StatusCode -ne 200) {
            throw "Unexpected pipeline definition update status: $($response.StatusCode)."
        }
        $operation = 'updated'
    }

    $items = @(Get-FabricItems -Uri "$base/items" -Headers $headers)
    $verified = @($items | Where-Object {
        $_.type -eq 'DataPipeline' -and
        $_.displayName -ceq $PipelineName -and
        $_.description -ceq $pipelineDescription
    })
    if ($verified.Count -ne 1) {
        throw "Pipeline item was not uniquely verified after it was $operation."
    }
    Write-Host "Pipeline definition ${operation}: $PipelineName."
    Write-Host 'The pipeline was not run; no Spark jobs or Silver/Gold tables were produced.'
} finally {
    $headers.Clear()
}
