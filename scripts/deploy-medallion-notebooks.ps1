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
    [string]$BronzeToSilverNotebookName = 'Macaw Bronze to Silver',
    [string]$SilverToGoldNotebookName = 'Macaw Silver to Gold',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($name in @(
    $BronzeName, $SilverName, $GoldName,
    $BronzeToSilverNotebookName, $SilverToGoldNotebookName
)) {
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'Lakehouse and notebook names must not be empty.'
    }
}
$notebookNames = @($BronzeToSilverNotebookName, $SilverToGoldNotebookName)
if (@($notebookNames | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
    throw 'Notebook names must be distinct.'
}

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$headers['x-ms-fabric-skill'] = 'e2e-medallion-architecture'
$api = 'https://api.fabric.microsoft.com/v1'
$base = "$api/workspaces/$WorkspaceId"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$builderPath = Join-Path $PSScriptRoot 'notebook_authoring.py'
$notebookSpecs = @(
    @{
        SourcePath = Join-Path $repoRoot 'notebooks\bronze_to_silver.py'
        DisplayName = $BronzeToSilverNotebookName
        Description = 'Macaw education Bronze-to-Silver validation and conformed Delta products.'
        LakehouseName = $BronzeName
    }
    @{
        SourcePath = Join-Path $repoRoot 'notebooks\silver_to_gold.py'
        DisplayName = $SilverToGoldNotebookName
        Description = 'Macaw education Silver-to-Gold agent-ready Delta products.'
        LakehouseName = $SilverName
    }
)

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
    foreach ($spec in $notebookSpecs) {
        if (-not (Test-Path -LiteralPath $spec.SourcePath -PathType Leaf)) {
            throw "Notebook source not found: $($spec.SourcePath)"
        }
        $lakehouseMatches = @($items | Where-Object {
            $_.type -eq 'Lakehouse' -and $_.displayName -ceq $spec.LakehouseName
        })
        if ($lakehouseMatches.Count -ne 1) {
            throw "Lakehouse '$($spec.LakehouseName)' was not uniquely found in the target workspace."
        }
        $sameName = @($items | Where-Object { $_.displayName -ceq $spec.DisplayName })
        $notebooks = @($sameName | Where-Object { $_.type -eq 'Notebook' })
        if ($sameName.Count -gt 1 -or ($sameName.Count -eq 1 -and $notebooks.Count -ne 1)) {
            throw "The name '$($spec.DisplayName)' is ambiguous or belongs to another item type."
        }
        if ($notebooks.Count -eq 1 -and $notebooks[0].description -cne $spec.Description) {
            throw "Existing notebook '$($spec.DisplayName)' is not the expected project item; inspect it."
        }
        if ($VerifyOnly -and $notebooks.Count -ne 1) {
            throw "Notebook '$($spec.DisplayName)' is missing in verify-only mode."
        }
    }

    if ($VerifyOnly) {
        Write-Host 'Both medallion notebook items and their target Lakehouses are present.'
        return
    }

    foreach ($spec in $notebookSpecs) {
        $items = @(Get-FabricItems -Uri "$base/items" -Headers $headers)
        $lakehouse = @($items | Where-Object {
            $_.type -eq 'Lakehouse' -and $_.displayName -ceq $spec.LakehouseName
        })
        $notebook = @($items | Where-Object {
            $_.type -eq 'Notebook' -and $_.displayName -ceq $spec.DisplayName
        })
        if ($lakehouse.Count -ne 1 -or $notebook.Count -gt 1) {
            throw "Workspace items changed while deploying '$($spec.DisplayName)'; inspect before retrying."
        }

        if ($notebook.Count -eq 0) {
            $createBody = @{
                displayName = $spec.DisplayName
                type = 'Notebook'
                description = $spec.Description
            } | ConvertTo-Json -Depth 6 -Compress
            $createResponse = Invoke-WebRequest -Method Post -Uri "$base/items" `
                -Headers $headers -ContentType 'application/json' -Body $createBody
            if ($createResponse.StatusCode -eq 202) {
                Wait-FabricOperation -Response $createResponse -Headers $headers
            } elseif ($createResponse.StatusCode -ne 201) {
                throw "Unexpected notebook creation status for '$($spec.DisplayName)': $($createResponse.StatusCode)."
            }
            $items = @(Get-FabricItems -Uri "$base/items" -Headers $headers)
            $notebook = @($items | Where-Object {
                $_.type -eq 'Notebook' -and $_.displayName -ceq $spec.DisplayName
            })
            if ($notebook.Count -ne 1 -or $notebook[0].description -cne $spec.Description) {
                throw "Created notebook '$($spec.DisplayName)' was not uniquely verified."
            }
        }

        $tempPath = Join-Path ([IO.Path]::GetTempPath()) "macaw-notebook-$([guid]::NewGuid()).ipynb"
        try {
            & python $builderPath `
                --source $spec.SourcePath `
                --workspace-id $WorkspaceId.ToString() `
                --lakehouse-id $lakehouse[0].id `
                --lakehouse-name $lakehouse[0].displayName `
                --bronze-lakehouse-name $BronzeName `
                --silver-lakehouse-name $SilverName `
                --gold-lakehouse-name $GoldName `
                --output $tempPath
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
                throw "Unable to build notebook definition for '$($spec.DisplayName)'."
            }

            $notebookBytes = [IO.File]::ReadAllBytes($tempPath)
            $payload = [Convert]::ToBase64String($notebookBytes)
            $updateBody = @{
                definition = @{
                    format = 'ipynb'
                    parts = @(@{
                        path = 'notebook-content.ipynb'
                        payload = $payload
                        payloadType = 'InlineBase64'
                    })
                }
            } | ConvertTo-Json -Depth 12 -Compress
            $updateResponse = Invoke-WebRequest -Method Post `
                -Uri "$base/notebooks/$($notebook[0].id)/updateDefinition" `
                -Headers $headers -ContentType 'application/json' -Body $updateBody
            if ($updateResponse.StatusCode -eq 202) {
                Wait-FabricOperation -Response $updateResponse -Headers $headers
            } elseif ($updateResponse.StatusCode -ne 200) {
                throw "Unexpected notebook update status for '$($spec.DisplayName)': $($updateResponse.StatusCode)."
            }
            Write-Host "Notebook content and Lakehouse binding deployed: $($spec.DisplayName)."
        } finally {
            if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
                Remove-Item -LiteralPath $tempPath -Force
            }
        }
    }

    Write-Host 'Notebook definitions are deployed. No Spark job was run and no data was materialized.'
} finally {
    $headers.Clear()
}
