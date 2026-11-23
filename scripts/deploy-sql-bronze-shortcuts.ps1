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

    [string]$SourceDatabaseName = 'MacawEducation',
    [string]$BronzeName = 'MacawEducationBronze',
    [string]$SkillAttribution = 'e2e-medallion-architecture',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$contractPath = Join-Path $PSScriptRoot '..\fabric\sql-bronze-tables.json'
$contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
$tables = @($contract.tables)
if ($contract.sourceSchema -cne 'dbo' -or $tables.Count -eq 0 -or
    @($tables.name | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
    throw 'The SQL Bronze table contract is invalid or contains duplicate tables.'
}
foreach ($table in $tables) {
    if ($table.name -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$' -or
        $table.name -like 'Analytics*' -or $table.name -like 'Security*' -or
        @($table.keyColumns).Count -eq 0 -or
        @($table.keyColumns | Where-Object { $_ -cnotmatch '^[A-Za-z][A-Za-z0-9_]*$' }).Count -gt 0 -or
        @($table.keyColumns | Group-Object | Where-Object Count -gt 1).Count -gt 0) {
        throw "Invalid or excluded table in the SQL Bronze contract: '$($table.name)'."
    }
}
if ([string]::IsNullOrWhiteSpace($SourceDatabaseName) -or
    [string]::IsNullOrWhiteSpace($BronzeName) -or
    [string]::IsNullOrWhiteSpace($SkillAttribution)) {
    throw 'Source name, Bronze name and Fabric skill attribution must not be empty.'
}

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$headers['x-ms-fabric-skill'] = $SkillAttribution
$api = 'https://api.fabric.microsoft.com/v1'
$base = "$api/workspaces/$WorkspaceId"

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

$items = @(Get-FabricItems -Uri "$base/items" -Headers $headers)
$source = @($items | Where-Object {
    $_.type -eq 'SQLDatabase' -and $_.id -eq $DatabaseItemId.ToString() -and
    $_.displayName -ceq $SourceDatabaseName
})
$bronze = @($items | Where-Object {
    $_.type -eq 'Lakehouse' -and $_.displayName -ceq $BronzeName
})
if ($source.Count -ne 1 -or $bronze.Count -ne 1) {
    throw 'The source SQL database or Bronze lakehouse was not uniquely found.'
}
$lakehouse = Invoke-RestMethod -Uri "$base/lakehouses/$($bronze[0].id)" -Headers $headers
if ($lakehouse.id -ne $bronze[0].id -or $lakehouse.workspaceId -ne $WorkspaceId.ToString() -or
    $lakehouse.description -ne 'Macaw education PoC Bronze lakehouse.' -or
    $lakehouse.properties.defaultSchema -ne 'dbo' -or
    $lakehouse.properties.sqlEndpointProperties.provisioningStatus -ne 'Success') {
    throw 'The Bronze lakehouse does not match the ready, schema-enabled project item.'
}
$filesUri = [uri]$lakehouse.properties.oneLakeFilesPath
$expectedFilesPath = "/$WorkspaceId/$($bronze[0].id)/Files"
if ($filesUri.Scheme -ne 'https' -or
    $filesUri.Host -notmatch '(^|-)onelake\.dfs\.fabric\.microsoft\.com$' -or
    $filesUri.AbsolutePath.TrimEnd('/') -ne $expectedFilesPath) {
    throw 'The Bronze OneLake Files path does not match the expected workspace and item.'
}
$filesPath = $filesUri.AbsoluteUri.TrimEnd('/')
$storageRoot = $filesUri.GetLeftPart([UriPartial]::Authority)

$storageToken = & az account get-access-token --subscription $SubscriptionId.ToString() `
    --resource 'https://storage.azure.com/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $storageToken) {
    throw 'Unable to acquire a OneLake access token for the selected subscription.'
}
$claimsPart = $storageToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
$claimsPart = $claimsPart.PadRight($claimsPart.Length + ((4 - $claimsPart.Length % 4) % 4), '=')
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($claimsPart)) | ConvertFrom-Json
if ($claims.tid -ne $TenantId.ToString() -or ([string]$claims.aud).TrimEnd('/') -ne 'https://storage.azure.com') {
    throw 'The OneLake token belongs to a different tenant or audience.'
}
$storageHeaders = @{ Authorization = "Bearer $storageToken"; 'x-ms-version' = '2023-08-03' }

try {
    $shortcutPath = 'Files/sql_mirror'
    $folderUri = "$filesPath/sql_mirror"
    $folderResponse = Invoke-WebRequest -Method Head -Uri $folderUri -Headers $storageHeaders -SkipHttpErrorCheck
    if ($folderResponse.StatusCode -eq 200) {
        if ([string]@($folderResponse.Headers['x-ms-resource-type'])[0] -ne 'directory') {
            throw 'The SQL mirror landing path exists but is not a directory.'
        }
        $folderExists = $true
    } elseif ($folderResponse.StatusCode -eq 404) {
        $folderExists = $false
    } else {
        throw "Unable to inspect the SQL mirror landing directory: HTTP $($folderResponse.StatusCode)."
    }

    $shortcuts = @(Get-FabricItems -Uri "$base/items/$($bronze[0].id)/shortcuts" -Headers $headers)
    $landingShortcuts = @($shortcuts | Where-Object { $_.path.TrimStart('/') -ceq $shortcutPath })
    $unexpected = @($shortcuts | Where-Object {
        $parent = $_.path.TrimStart('/')
        ($parent -ceq 'Files' -and $_.name -ceq 'sql_mirror') -or
        ($parent -ceq $shortcutPath -and $_.name -cnotin $tables.name) -or
        $parent.StartsWith("$shortcutPath/", [StringComparison]::Ordinal)
    })
    if ($unexpected.Count -gt 0) {
        throw 'The SQL mirror landing directory contains shortcuts outside the reviewed table contract.'
    }

    $missing = @()
    foreach ($table in $tables) {
        $sourceLog = "$storageRoot/$WorkspaceId/$DatabaseItemId/Tables/$($contract.sourceSchema)/$($table.name)/_delta_log"
        $sourceResponse = Invoke-WebRequest -Method Head -Uri $sourceLog -Headers $storageHeaders -SkipHttpErrorCheck
        if ($sourceResponse.StatusCode -ne 200) {
            throw "The mirrored Delta log for '$($table.name)' is not accessible: HTTP $($sourceResponse.StatusCode)."
        }

        $existing = @($landingShortcuts | Where-Object { $_.name -ceq $table.name })
        if ($existing.Count -gt 1) {
            throw "Multiple shortcuts exist for '$($table.name)'; inspect them before proceeding."
        }
        if ($existing.Count -eq 1) {
            $target = $existing[0].target
            if (-not $target.PSObject.Properties['oneLake'] -or -not $target.oneLake -or
                $target.oneLake.workspaceId -ne $WorkspaceId.ToString() -or
                $target.oneLake.itemId -ne $DatabaseItemId.ToString() -or
                $target.oneLake.path -cne "Tables/$($contract.sourceSchema)/$($table.name)" -or
                ($target.oneLake.PSObject.Properties['connectionId'] -and $target.oneLake.connectionId)) {
                throw "Shortcut '$($table.name)' points to an unexpected or delegated target."
            }
        } else {
            if ($folderExists) {
                $collision = Invoke-WebRequest -Method Head -Uri "$folderUri/$($table.name)" `
                    -Headers $storageHeaders -SkipHttpErrorCheck
                if ($collision.StatusCode -ne 404) {
                    throw "A path already exists or cannot be inspected for '$($table.name)': HTTP $($collision.StatusCode)."
                }
            }
            $missing += $table
        }
    }

    if ($VerifyOnly -and (-not $folderExists -or $missing.Count -gt 0)) {
        throw "SQL mirror shortcuts missing in verify-only mode: $(($missing.name) -join ', ')."
    }
    if (-not $folderExists) {
        $createHeaders = $storageHeaders.Clone()
        $createHeaders['If-None-Match'] = '*'
        $folderResponse = Invoke-WebRequest -Method Put -Uri "${folderUri}?resource=directory" `
            -Headers $createHeaders -Body '' -SkipHttpErrorCheck
        if ($folderResponse.StatusCode -ne 201) {
            throw "The SQL mirror landing directory was not created: HTTP $($folderResponse.StatusCode). Inspect before retrying."
        }
    }

    foreach ($table in $missing) {
        $body = @{
            path = $shortcutPath
            name = $table.name
            target = @{
                oneLake = @{
                    workspaceId = $WorkspaceId.ToString()
                    itemId = $DatabaseItemId.ToString()
                    path = "Tables/$($contract.sourceSchema)/$($table.name)"
                }
            }
        } | ConvertTo-Json -Depth 6 -Compress
        $response = Invoke-WebRequest -Method Post -Uri "$base/items/$($bronze[0].id)/shortcuts" `
            -Headers $headers -ContentType 'application/json' -Body $body -SkipHttpErrorCheck
        if ($response.StatusCode -ne 201) {
            throw "Shortcut '$($table.name)' was not created: HTTP $($response.StatusCode). Inspect before retrying."
        }
    }

    $shortcuts = @(Get-FabricItems -Uri "$base/items/$($bronze[0].id)/shortcuts" -Headers $headers)
    foreach ($table in $tables) {
        $matches = @($shortcuts | Where-Object {
            $_.path.TrimStart('/') -ceq $shortcutPath -and $_.name -ceq $table.name
        })
        if ($matches.Count -ne 1 -or
            -not $matches[0].target.PSObject.Properties['oneLake'] -or
            $matches[0].target.oneLake.workspaceId -ne $WorkspaceId.ToString() -or
            $matches[0].target.oneLake.itemId -ne $DatabaseItemId.ToString() -or
            $matches[0].target.oneLake.path -cne "Tables/$($contract.sourceSchema)/$($table.name)" -or
            ($matches[0].target.oneLake.PSObject.Properties['connectionId'] -and
                $matches[0].target.oneLake.connectionId)) {
            throw "Shortcut '$($table.name)' did not resolve to the expected target."
        }
        $logResponse = Invoke-WebRequest -Method Head -Uri "$folderUri/$($table.name)/_delta_log" `
            -Headers $storageHeaders -SkipHttpErrorCheck
        if ($logResponse.StatusCode -ne 200) {
            throw "Shortcut '$($table.name)' cannot read its Delta log: HTTP $($logResponse.StatusCode)."
        }
    }
    Write-Host "Verified $($tables.Count) allowlisted SQL-mirror shortcuts in Bronze Files."
    Write-Host 'No data was materialized and no permissions were granted. Restricted access remains unverified.'
} finally {
    $storageHeaders.Clear()
    $headers.Clear()
    if (Get-Variable -Name createHeaders -ErrorAction SilentlyContinue) { $createHeaders.Clear() }
    $storageToken = $null
}
