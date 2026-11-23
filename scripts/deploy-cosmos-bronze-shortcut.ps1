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
    $targetPath = "Tables/$DatabaseName/FacilityIncidents"
    $sourceResponse = Invoke-WebRequest -Method Head `
        -Uri "$storageRoot/$WorkspaceId/$($database.id)/$targetPath/_delta_log" `
        -Headers $storageHeaders -SkipHttpErrorCheck
    if ($sourceResponse.StatusCode -ne 200) {
        throw "The mirrored Cosmos Delta log is not accessible: HTTP $($sourceResponse.StatusCode)."
    }

    $folderUri = "$($filesUri.AbsoluteUri.TrimEnd('/'))/cosmos_mirror"
    $folderResponse = Invoke-WebRequest -Method Head -Uri $folderUri -Headers $storageHeaders -SkipHttpErrorCheck
    if ($folderResponse.StatusCode -eq 200) {
        if ([string]@($folderResponse.Headers['x-ms-resource-type'])[0] -ne 'directory') {
            throw 'The Cosmos mirror landing path is not a directory.'
        }
        $folderExists = $true
    } elseif ($folderResponse.StatusCode -eq 404) {
        $folderExists = $false
    } else {
        throw "Unable to inspect the Cosmos mirror landing directory: HTTP $($folderResponse.StatusCode)."
    }
    $shortcuts = @(Get-FabricItems -Uri "$base/items/$($bronze[0].id)/shortcuts" -Headers $headers)
    $existing = @($shortcuts | Where-Object {
        $_.path.TrimStart('/') -ceq 'Files/cosmos_mirror' -and $_.name -ceq 'FacilityIncidents'
    })
    if ($existing.Count -gt 1) {
        throw 'Multiple Cosmos incident shortcuts were found; inspect them before proceeding.'
    }
    if ($existing.Count -eq 1) {
        $target = $existing[0].target
        if (-not $target.PSObject.Properties['oneLake'] -or -not $target.oneLake -or
            $target.oneLake.workspaceId -ne $WorkspaceId.ToString() -or
            $target.oneLake.itemId -ne $database.id -or
            $target.oneLake.path -cne $targetPath -or
            ($target.oneLake.PSObject.Properties['connectionId'] -and $target.oneLake.connectionId)) {
            throw 'The existing Cosmos incident shortcut points to an unexpected or delegated target.'
        }
    } else {
        if ($VerifyOnly) {
            throw 'The Cosmos incident shortcut is missing in verify-only mode.'
        }
        if ($folderExists) {
            $collision = Invoke-WebRequest -Method Head -Uri "$folderUri/FacilityIncidents" `
                -Headers $storageHeaders -SkipHttpErrorCheck
            if ($collision.StatusCode -ne 404) {
                throw "The Cosmos shortcut path already exists or cannot be inspected: HTTP $($collision.StatusCode)."
            }
        } else {
            $createHeaders = $storageHeaders.Clone()
            $createHeaders['If-None-Match'] = '*'
            $createdFolder = Invoke-WebRequest -Method Put -Uri "${folderUri}?resource=directory" `
                -Headers $createHeaders -Body '' -SkipHttpErrorCheck
            if ($createdFolder.StatusCode -ne 201) {
                throw "The Cosmos mirror directory was not created: HTTP $($createdFolder.StatusCode)."
            }
        }
        $body = @{
            path = 'Files/cosmos_mirror'
            name = 'FacilityIncidents'
            target = @{
                oneLake = @{
                    workspaceId = $WorkspaceId.ToString()
                    itemId = $database.id
                    path = $targetPath
                }
            }
        } | ConvertTo-Json -Depth 6 -Compress
        $created = Invoke-WebRequest -Method Post -Uri "$base/items/$($bronze[0].id)/shortcuts" `
            -Headers $headers -ContentType 'application/json' -Body $body -SkipHttpErrorCheck
        if ($created.StatusCode -ne 201) {
            throw "The Cosmos shortcut was not created: HTTP $($created.StatusCode). Inspect before retrying."
        }
    }

    $shortcuts = @(Get-FabricItems -Uri "$base/items/$($bronze[0].id)/shortcuts" -Headers $headers)
    $confirmed = @($shortcuts | Where-Object {
        $_.path.TrimStart('/') -ceq 'Files/cosmos_mirror' -and $_.name -ceq 'FacilityIncidents'
    })
    if ($confirmed.Count -ne 1 -or
        -not $confirmed[0].target.PSObject.Properties['oneLake'] -or
        $confirmed[0].target.oneLake.workspaceId -ne $WorkspaceId.ToString() -or
        $confirmed[0].target.oneLake.itemId -ne $database.id -or
        $confirmed[0].target.oneLake.path -cne $targetPath -or
        ($confirmed[0].target.oneLake.PSObject.Properties['connectionId'] -and
            $confirmed[0].target.oneLake.connectionId)) {
        throw 'The Cosmos incident shortcut did not resolve to the expected target.'
    }
    $log = Invoke-WebRequest -Method Head -Uri "$folderUri/FacilityIncidents/_delta_log" `
        -Headers $storageHeaders -SkipHttpErrorCheck
    if ($log.StatusCode -ne 200) {
        throw "The Cosmos shortcut cannot read its Delta log: HTTP $($log.StatusCode)."
    }
    Write-Host 'Verified the Cosmos incident mirror shortcut in Bronze Files.'
    Write-Host 'The shortcut does not grant access or establish restricted-user isolation.'
} finally {
    $headers.Clear()
    $storageHeaders.Clear()
    $storageToken = $null
}
