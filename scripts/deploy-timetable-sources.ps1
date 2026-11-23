[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$WorkspaceId,

    [string]$BronzeName = 'MacawEducationBronze',
    [string]$SkillAttribution = 'e2e-medallion-architecture',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($BronzeName) -or
    [string]::IsNullOrWhiteSpace($SkillAttribution)) {
    throw 'Bronze name and Fabric skill attribution must not be empty.'
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$sourceRoot = Join-Path $repoRoot 'data\sources'
$manifestPath = Join-Path $sourceRoot 'timetable\manifest_2026_2027.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Timetable manifest not found: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.batchId -cne 'timetable-2026-2027-v2' -or
    $manifest.academicYear -cne '2026-2027' -or
    -not $manifest.files.timetable -or -not $manifest.files.regionalHolidays -or
    $manifest.files.timetable.rowCount -ne 2485 -or
    $manifest.files.regionalHolidays.rowCount -ne 21) {
    throw 'The generated timetable manifest is incomplete or unexpected.'
}

$filePlan = @(
    [pscustomobject]@{
        Name = 'timetable'
        SourcePath = Join-Path $sourceRoot $manifest.files.timetable.path
        OneLakePath = [string]$manifest.files.timetable.oneLakePath
        Sha256 = ([string]$manifest.files.timetable.sha256).ToLowerInvariant()
        ExpectedRows = 2485
    },
    [pscustomobject]@{
        Name = 'regional holidays'
        SourcePath = Join-Path $sourceRoot $manifest.files.regionalHolidays.path
        OneLakePath = [string]$manifest.files.regionalHolidays.oneLakePath
        Sha256 = ([string]$manifest.files.regionalHolidays.sha256).ToLowerInvariant()
        ExpectedRows = 21
    }
)
foreach ($file in $filePlan) {
    if (-not (Test-Path -LiteralPath $file.SourcePath -PathType Leaf) -or
        $file.Sha256 -cnotmatch '^[0-9a-f]{64}$' -or
        $file.OneLakePath -notlike 'Files/landing/*') {
        throw "Invalid generated source contract for $($file.Name)."
    }
    if ((Get-FileHash -LiteralPath $file.SourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.Sha256) {
        throw "The generated source checksum does not match the manifest for $($file.Name)."
    }
}
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$filePlan += [pscustomobject]@{
    Name = 'source manifest'
    SourcePath = $manifestPath
    OneLakePath = "Files/landing/timetable/$($manifest.batchId)/manifest_2026_2027.json"
    Sha256 = $manifestHash
    ExpectedRows = 0
}

. (Join-Path $PSScriptRoot 'fabric-api.ps1')
$headers = Get-FabricHeaders -SubscriptionId $SubscriptionId -TenantId $TenantId
$headers['x-ms-fabric-skill'] = $SkillAttribution
$api = 'https://api.fabric.microsoft.com/v1'
$base = "$api/workspaces/$WorkspaceId"

$storageToken = $null
$storageHeaders = $null
try {
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
    $items = @(Get-FabricItems -Uri "$base/items" -Headers $headers |
        Where-Object { $_.type -eq 'Lakehouse' -and $_.displayName -ceq $BronzeName })
    if ($items.Count -ne 1) {
        throw "Bronze lakehouse '$BronzeName' was not uniquely found."
    }
    $lakehouse = Invoke-RestMethod -Uri "$base/lakehouses/$($items[0].id)" -Headers $headers
    if ($lakehouse.id -ne $items[0].id -or
        $lakehouse.workspaceId -ne $WorkspaceId.ToString() -or
        $lakehouse.description -ne 'Macaw education PoC Bronze lakehouse.' -or
        $lakehouse.properties.sqlEndpointProperties.provisioningStatus -ne 'Success') {
        throw 'The Bronze lakehouse does not match the ready project item.'
    }

    $filesUri = [uri]$lakehouse.properties.oneLakeFilesPath
    $expectedFilesPath = "/$WorkspaceId/$($items[0].id)/Files"
    if ($filesUri.Scheme -ne 'https' -or
        $filesUri.Host -notmatch '(^|-)onelake\.dfs\.fabric\.microsoft\.com$' -or
        $filesUri.AbsolutePath.TrimEnd('/') -ne $expectedFilesPath) {
        throw 'The Bronze OneLake Files path does not match the expected workspace and item.'
    }
    $filesPath = $filesUri.AbsoluteUri.TrimEnd('/')

    $storageToken = & az account get-access-token --subscription $SubscriptionId.ToString() `
        --resource 'https://storage.azure.com/' --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $storageToken) {
        throw 'Unable to acquire a OneLake access token for the selected subscription.'
    }
    $claimsPart = $storageToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $claimsPart = $claimsPart.PadRight($claimsPart.Length + ((4 - $claimsPart.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($claimsPart)) |
        ConvertFrom-Json
    if ($claims.tid -ne $TenantId.ToString() -or
        ([string]$claims.aud).TrimEnd('/') -ne 'https://storage.azure.com') {
        throw 'The OneLake token belongs to a different tenant or audience.'
    }
    $storageHeaders = @{
        Authorization = "Bearer $storageToken"
        'x-ms-version' = '2021-06-08'
    }

    $paths = [Collections.Generic.List[string]]::new()
    foreach ($file in $filePlan) {
        $relativePath = $file.OneLakePath.Substring('Files/'.Length)
        if ($relativePath -match '(^|/)\.\.?(/|$)' -or $relativePath.StartsWith('/')) {
            throw "Unsafe OneLake path in the source manifest: $($file.OneLakePath)"
        }
        $segments = @($relativePath -split '/')
        $directory = ''
        for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
            $directory = if ($directory) { "$directory/$($segments[$index])" } else { $segments[$index] }
            if ($paths -notcontains $directory) { $paths.Add($directory) }
        }
    }

    foreach ($directory in $paths) {
        $escapedDirectory = [string]::Join('/', @($directory -split '/' | ForEach-Object {
            [uri]::EscapeDataString($_)
        }))
        $directoryUri = "$filesPath/$escapedDirectory"
        $response = Invoke-WebRequest -Method Head -Uri $directoryUri `
            -Headers $storageHeaders -SkipHttpErrorCheck
        if ($response.StatusCode -eq 200) {
            if ([string]@($response.Headers['x-ms-resource-type'])[0] -ne 'directory') {
                throw "The landing path exists but is not a directory: $directory"
            }
        } elseif ($response.StatusCode -eq 404) {
            if ($VerifyOnly) {
                throw "The landing directory is missing in verify-only mode: $directory"
            }
            $createHeaders = $storageHeaders.Clone()
            $createHeaders['If-None-Match'] = '*'
            $response = Invoke-WebRequest -Method Put -Uri "${directoryUri}?resource=directory" `
                -Headers $createHeaders -Body '' -SkipHttpErrorCheck
            if ($response.StatusCode -ne 201) {
                throw "The landing directory was not created: $directory (HTTP $($response.StatusCode))."
            }
        } else {
            throw "Unable to inspect the landing directory '$directory': HTTP $($response.StatusCode)."
        }
    }

    foreach ($file in $filePlan) {
        $relativePath = $file.OneLakePath.Substring('Files/'.Length)
        $escapedPath = [string]::Join('/', @($relativePath -split '/' | ForEach-Object {
            [uri]::EscapeDataString($_)
        }))
        $fileUri = "$filesPath/$escapedPath"
        $downloadPath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $fileCreated = $false
        try {
            $response = Invoke-WebRequest -Method Get -Uri $fileUri `
                -Headers $storageHeaders -OutFile $downloadPath -PassThru -SkipHttpErrorCheck
            if ($response.StatusCode -eq 200) {
                $remoteHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($remoteHash -cne $file.Sha256) {
                    throw "An immutable Bronze landing path already exists with different content: $($file.OneLakePath)"
                }
                continue
            }
            if ($response.StatusCode -ne 404) {
                throw "Unable to inspect the landing file '$($file.OneLakePath)': HTTP $($response.StatusCode)."
            }
            if ($VerifyOnly) {
                throw "The landing file is missing in verify-only mode: $($file.OneLakePath)"
            }

            $createResponse = Invoke-WebRequest -Method Put -Uri "${fileUri}?resource=file" `
                -Headers $storageHeaders -Body '' -SkipHttpErrorCheck
            if ($createResponse.StatusCode -ne 201) {
                throw "The landing file was not created: $($file.OneLakePath) (HTTP $($createResponse.StatusCode))."
            }
            $fileCreated = $true
            $length = (Get-Item -LiteralPath $file.SourcePath).Length
            $appendResponse = Invoke-WebRequest -Method Patch `
                -Uri "${fileUri}?action=append&position=0" -Headers $storageHeaders `
                -InFile $file.SourcePath -SkipHttpErrorCheck
            if ($appendResponse.StatusCode -ne 202) {
                throw "The landing file append failed: $($file.OneLakePath) (HTTP $($appendResponse.StatusCode))."
            }
            $flushResponse = Invoke-WebRequest -Method Patch `
                -Uri "${fileUri}?action=flush&position=$length" -Headers $storageHeaders `
                -Body '' -SkipHttpErrorCheck
            if ($flushResponse.StatusCode -ne 200) {
                throw "The landing file flush failed: $($file.OneLakePath) (HTTP $($flushResponse.StatusCode))."
            }

            $response = Invoke-WebRequest -Method Get -Uri $fileUri `
                -Headers $storageHeaders -OutFile $downloadPath -PassThru -SkipHttpErrorCheck
            if ($response.StatusCode -ne 200 -or
                (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.Sha256) {
                throw "The uploaded landing file did not match its source checksum: $($file.OneLakePath)"
            }
        } catch {
            if ($fileCreated) {
                try {
                    $deleteResponse = Invoke-WebRequest -Method Delete -Uri $fileUri `
                        -Headers $storageHeaders -SkipHttpErrorCheck
                    if ($deleteResponse.StatusCode -notin 200, 202, 204) {
                        Write-Warning "Could not remove the incomplete landing file '$($file.OneLakePath)' (HTTP $($deleteResponse.StatusCode))."
                    }
                } catch {
                    Write-Warning "Could not remove the incomplete landing file '$($file.OneLakePath)': $($_.Exception.Message)"
                }
            }
            throw
        } finally {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Verified $($filePlan.Count) immutable Bronze landing files for batch $($manifest.batchId)."
    Write-Host 'The files are raw planned schedules and holiday references; no observations or permissions were created.'
} finally {
    if ($storageHeaders) { $storageHeaders.Clear() }
    $storageToken = $null
    $headers.Clear()
}
