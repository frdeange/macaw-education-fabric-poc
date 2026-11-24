[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$WorkspaceId,

    [string]$DatabaseName = 'MacawFacilitiesIncidents',
    [string]$BronzeName = 'MacawEducationBronze',
    [string]$SkillAttribution = 'e2e-medallion-architecture',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($DatabaseName -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$' -or
    [string]::IsNullOrWhiteSpace($BronzeName) -or
    [string]::IsNullOrWhiteSpace($SkillAttribution)) {
    throw 'The Cosmos database, Bronze lakehouse, or skill attribution is invalid.'
}
if (-not $VerifyOnly) {
    throw 'Creation of the legacy Files shortcut is retired. Manage the schema shortcut in Fabric and use -VerifyOnly.'
}

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$headers['x-ms-fabric-skill'] = $SkillAttribution
$api = 'https://api.fabric.microsoft.com/v1'
$base = "$api/workspaces/$WorkspaceId"
$storageHeaders = @{}
$storageToken = $null

try {
    $databases = @(Get-FabricItems -Uri "$base/cosmosDbDatabases" -Headers $headers |
        Where-Object { $_.displayName -ceq $DatabaseName })
    $bronze = @(Get-FabricItems -Uri "$base/items" -Headers $headers |
        Where-Object { $_.type -eq 'Lakehouse' -and $_.displayName -ceq $BronzeName })
    if ($databases.Count -ne 1 -or $bronze.Count -ne 1 -or
        $databases[0].description -cne 'Macaw education PoC synthetic facilities incidents.') {
        throw 'The project Cosmos database or Bronze lakehouse was not uniquely found.'
    }
    $database = Invoke-RestMethod -Uri "$base/cosmosDbDatabases/$($databases[0].id)" -Headers $headers
    $lakehouse = Invoke-RestMethod -Uri "$base/lakehouses/$($bronze[0].id)" -Headers $headers
    if ($database.workspaceId -ne $WorkspaceId.ToString() -or
        $database.properties.databaseName -cne $DatabaseName -or
        $lakehouse.workspaceId -ne $WorkspaceId.ToString() -or
        $lakehouse.description -cne 'Macaw education PoC Bronze lakehouse.' -or
        $lakehouse.properties.defaultSchema -cne 'dbo' -or
        $lakehouse.properties.sqlEndpointProperties.provisioningStatus -ne 'Success') {
        throw 'The Cosmos database or Bronze lakehouse metadata does not match the project.'
    }
    $filesUri = [uri]$lakehouse.properties.oneLakeFilesPath
    if ($filesUri.Scheme -ne 'https' -or
        $filesUri.Host -notmatch '(^|-)onelake\.dfs\.fabric\.microsoft\.com$' -or
        $filesUri.AbsolutePath.TrimEnd('/') -cne "/$WorkspaceId/$($bronze[0].id)/Files") {
        throw 'The Bronze OneLake Files path does not match the workspace and item.'
    }
    $storageRoot = $filesUri.GetLeftPart([UriPartial]::Authority)
    $storageToken = & az account get-access-token --subscription $SubscriptionId.ToString() `
        --resource 'https://storage.azure.com/' --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $storageToken) {
        throw 'Unable to acquire a OneLake access token for the selected subscription.'
    }
    $claimsPart = $storageToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $claimsPart = $claimsPart.PadRight($claimsPart.Length + ((4 - $claimsPart.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($claimsPart)) | ConvertFrom-Json
    if ($claims.tid -ne $TenantId.ToString() -or
        ([string]$claims.aud).TrimEnd('/') -ne 'https://storage.azure.com') {
        throw 'The OneLake token belongs to a different tenant or audience.'
    }
    $storageHeaders = @{ Authorization = "Bearer $storageToken"; 'x-ms-version' = '2023-08-03' }
    $targetPath = "Tables/$DatabaseName"
    $sourceResponse = Invoke-WebRequest -Method Head `
        -Uri "$storageRoot/$WorkspaceId/$($database.id)/$targetPath/FacilityIncidents/_delta_log" `
        -Headers $storageHeaders -SkipHttpErrorCheck
    if ($sourceResponse.StatusCode -ne 200) {
        throw "The mirrored Cosmos Delta log is not accessible: HTTP $($sourceResponse.StatusCode)."
    }

    $shortcuts = @(Get-FabricItems -Uri "$base/items/$($bronze[0].id)/shortcuts" -Headers $headers)
    $existing = @($shortcuts | Where-Object {
        $_.path.TrimStart('/') -ceq 'Tables' -and $_.name -ceq 'CosmosDB'
    })
    if ($existing.Count -ne 1) {
        throw 'The Cosmos schema shortcut is missing or ambiguous in verify-only mode.'
    }
    $target = $existing[0].target
    if (-not $target.PSObject.Properties['oneLake'] -or -not $target.oneLake -or
        $target.oneLake.workspaceId -ne $WorkspaceId.ToString() -or
        $target.oneLake.itemId -ne $database.id -or
        $target.oneLake.path -cne $targetPath -or
        ($target.oneLake.PSObject.Properties['connectionId'] -and $target.oneLake.connectionId)) {
        throw 'The Cosmos schema shortcut points to an unexpected or delegated target.'
    }
    $legacy = @($shortcuts | Where-Object {
        $parent = $_.path.TrimStart('/')
        ($parent -ceq 'Files' -and $_.name -ceq 'cosmos_mirror') -or
        $parent -ceq 'Files/cosmos_mirror' -or
        $parent.StartsWith('Files/cosmos_mirror/', [StringComparison]::Ordinal)
    })
    if ($legacy.Count -gt 0) {
        throw 'Legacy Cosmos Files shortcuts still exist; inspect them before proceeding.'
    }
    $log = Invoke-WebRequest -Method Head `
        -Uri "$storageRoot/$WorkspaceId/$($bronze[0].id)/Tables/CosmosDB/FacilityIncidents/_delta_log" `
        -Headers $storageHeaders -SkipHttpErrorCheck
    if ($log.StatusCode -ne 200) {
        throw "The Cosmos shortcut cannot read its Delta log: HTTP $($log.StatusCode)."
    }
    Write-Host "Verified the Cosmos incident table through the Bronze 'CosmosDB' schema shortcut."
    Write-Host 'A schema shortcut exposes the entire source schema, including any future tables.'
    Write-Host 'The shortcut does not grant access or establish restricted-user isolation.'
} finally {
    $headers.Clear()
    $storageHeaders.Clear()
    $storageToken = $null
}
