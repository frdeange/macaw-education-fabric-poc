$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$deployment = Join-Path $root 'scripts\deploy-timetable-sources.ps1'
$manifest = Get-Content -LiteralPath (Join-Path $root 'data\sources\timetable\manifest_2026_2027.json') -Raw |
    ConvertFrom-Json
$workspaceId = [guid]'00000000-0000-0000-0000-000000000001'
$subscriptionId = [guid]'00000000-0000-0000-0000-000000000002'
$tenantId = [guid]'00000000-0000-0000-0000-000000000003'
$capacityId = [guid]'00000000-0000-0000-0000-000000000004'
$bronzeId = [guid]'00000000-0000-0000-0000-000000000005'
$global:MacawTimetableUploadTest = $null

function Reset-Fixture {
    $global:MacawTimetableUploadTest = @{
        Directories = @{}
        RemoteFiles = @{}
        CapacityState = 'Active'
        TokenAudience = 'https://storage.azure.com/'
        AppendStatus = 202
        Requests = 0
    }
}

function az {
    $audience = if ($args -contains 'https://storage.azure.com/') {
        $global:MacawTimetableUploadTest.TokenAudience
    } else {
        'https://api.fabric.microsoft.com'
    }
    $claims = @{ tid = $tenantId.ToString(); aud = $audience } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).
        TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $global:LASTEXITCODE = 0
    "header.$payload.signature"
}

function Assert-FabricHeader {
    param($Headers)
    if ($Headers['x-ms-fabric-skill'] -ne 'e2e-medallion-architecture') {
        throw 'Missing Fabric skill attribution.'
    }
}

function Invoke-RestMethod {
    param([string]$Uri, $Headers)
    Assert-FabricHeader $Headers
    $path = ([uri]$Uri).AbsolutePath
    if ($path -eq '/v1/workspaces') {
        return [pscustomobject]@{
            value = @([pscustomobject]@{ id = $workspaceId.ToString(); capacityId = $capacityId.ToString() })
        }
    }
    if ($path -eq '/v1/capacities') {
        return [pscustomobject]@{
            value = @([pscustomobject]@{
                id = $capacityId.ToString()
                state = $global:MacawTimetableUploadTest.CapacityState
            })
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/items") {
        return [pscustomobject]@{
            value = @([pscustomobject]@{
                id = $bronzeId.ToString()
                type = 'Lakehouse'
                displayName = 'MacawEducationBronze'
            })
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/lakehouses/$bronzeId") {
        return [pscustomobject]@{
            id = $bronzeId.ToString()
            workspaceId = $workspaceId.ToString()
            description = 'Macaw education PoC Bronze lakehouse.'
            properties = [pscustomobject]@{
                oneLakeFilesPath = "https://onelake.dfs.fabric.microsoft.com/$workspaceId/$bronzeId/Files"
                sqlEndpointProperties = [pscustomobject]@{ provisioningStatus = 'Success' }
            }
        }
    }
    throw "Unexpected fixture GET: $path"
}

function Invoke-WebRequest {
    param(
        [string]$Method,
        [string]$Uri,
        $Headers,
        [string]$Body,
        [string]$InFile,
        [string]$OutFile,
        [switch]$PassThru,
        [switch]$SkipHttpErrorCheck
    )
    $global:MacawTimetableUploadTest.Requests++
    $parsed = [uri]$Uri
    $path = $parsed.AbsolutePath
    $query = [System.Web.HttpUtility]::ParseQueryString($parsed.Query)

    if ($Method -eq 'Head') {
        $status = if ($global:MacawTimetableUploadTest.Directories.ContainsKey($path)) { 200 } else { 404 }
        return [pscustomobject]@{
            StatusCode = $status
            Headers = @{ 'x-ms-resource-type' = 'directory' }
        }
    }
    if ($Method -eq 'Put' -and $query['resource'] -eq 'directory') {
        if ($Headers['If-None-Match'] -ne '*') {
            throw 'Directory creation was not protected against an existing path.'
        }
        $global:MacawTimetableUploadTest.Directories[$path] = $true
        return [pscustomobject]@{ StatusCode = 201; Headers = @{} }
    }
    if ($Method -eq 'Put' -and $query['resource'] -eq 'file') {
        $global:MacawTimetableUploadTest.RemoteFiles[$path] = @{
            Bytes = [byte[]]@()
            Complete = $false
        }
        return [pscustomobject]@{ StatusCode = 201; Headers = @{} }
    }
    if ($Method -eq 'Patch' -and $query['action'] -eq 'append') {
        if ($global:MacawTimetableUploadTest.AppendStatus -ne 202) {
            return [pscustomobject]@{
                StatusCode = $global:MacawTimetableUploadTest.AppendStatus
                Headers = @{}
            }
        }
        $entry = $global:MacawTimetableUploadTest.RemoteFiles[$path]
        $entry.Bytes = [IO.File]::ReadAllBytes($InFile)
        return [pscustomobject]@{ StatusCode = 202; Headers = @{} }
    }
    if ($Method -eq 'Patch' -and $query['action'] -eq 'flush') {
        $global:MacawTimetableUploadTest.RemoteFiles[$path].Complete = $true
        return [pscustomobject]@{ StatusCode = 200; Headers = @{} }
    }
    if ($Method -eq 'Get') {
        if (-not $global:MacawTimetableUploadTest.RemoteFiles.ContainsKey($path) -or
            -not $global:MacawTimetableUploadTest.RemoteFiles[$path].Complete) {
            return [pscustomobject]@{ StatusCode = 404; Headers = @{} }
        }
        [IO.File]::WriteAllBytes($OutFile, $global:MacawTimetableUploadTest.RemoteFiles[$path].Bytes)
        return [pscustomobject]@{ StatusCode = 200; Headers = @{} }
    }
    if ($Method -eq 'Delete') {
        $global:MacawTimetableUploadTest.RemoteFiles.Remove($path)
        return [pscustomobject]@{ StatusCode = 204; Headers = @{} }
    }
    throw "Unexpected fixture request: $Method $Uri"
}

function Invoke-Deployment {
    param([switch]$VerifyOnly)
    & $deployment -SubscriptionId $subscriptionId -TenantId $tenantId `
        -WorkspaceId $workspaceId -VerifyOnly:$VerifyOnly
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Expected)
    try { & $Action } catch {
        if ($_.Exception.Message -like "*$Expected*") { return }
        throw
    }
    throw "Expected an error containing '$Expected'."
}

try {
    Reset-Fixture
    Invoke-Deployment
    if ($global:MacawTimetableUploadTest.RemoteFiles.Count -ne 3) {
        throw 'Expected the timetable, holiday extract and source manifest to be uploaded.'
    }
    $requestCount = $global:MacawTimetableUploadTest.Requests
    Invoke-Deployment -VerifyOnly
    Invoke-Deployment
    if ($global:MacawTimetableUploadTest.RemoteFiles.Count -ne 3 -or
        $global:MacawTimetableUploadTest.Requests -le $requestCount) {
        throw 'Verification or rerunning changed the immutable source files.'
    }

    Reset-Fixture
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'missing in verify-only mode'
    if ($global:MacawTimetableUploadTest.RemoteFiles.Count -ne 0 -or
        $global:MacawTimetableUploadTest.Directories.Count -ne 0) {
        throw 'Verify-only mode created a OneLake path.'
    }

    Reset-Fixture
    $global:MacawTimetableUploadTest.CapacityState = 'Paused'
    Assert-Throws { Invoke-Deployment } 'not uniquely visible and active'
    if ($global:MacawTimetableUploadTest.RemoteFiles.Count -ne 0) {
        throw 'The uploader wrote to an inactive capacity.'
    }

    Reset-Fixture
    $global:MacawTimetableUploadTest.TokenAudience = 'https://wrong.example/'
    Assert-Throws { Invoke-Deployment } 'different tenant or audience'
    if ($global:MacawTimetableUploadTest.RemoteFiles.Count -ne 0) {
        throw 'The uploader wrote with the wrong token audience.'
    }

    Reset-Fixture
    Invoke-Deployment
    $timetablePath = "/$workspaceId/$bronzeId/Files/$($manifest.files.timetable.oneLakePath.Substring('Files/'.Length))"
    $conflictingFile = $global:MacawTimetableUploadTest.RemoteFiles[$timetablePath]
    $conflictingFile['Bytes'] = [byte[]](1, 2, 3)
    Assert-Throws { Invoke-Deployment } 'immutable Bronze landing path already exists with different content'
    if ($global:MacawTimetableUploadTest.RemoteFiles[$timetablePath].Bytes.Length -ne 3) {
        throw 'A conflicting immutable source file was overwritten.'
    }

    Reset-Fixture
    $global:MacawTimetableUploadTest.AppendStatus = 400
    Assert-Throws { Invoke-Deployment } 'append failed'
    if ($global:MacawTimetableUploadTest.RemoteFiles.Count -ne 0) {
        throw 'An incomplete landing file was not removed after an append failure.'
    }
} finally {
    Remove-Variable -Name MacawTimetableUploadTest -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Timetable source deployment tests passed.'
