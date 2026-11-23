$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$deployment = Join-Path $root 'scripts\deploy-sql-bronze-shortcuts.ps1'
$contract = Get-Content -LiteralPath (Join-Path $root 'fabric\sql-bronze-tables.json') -Raw | ConvertFrom-Json
$workspaceId = [guid]'00000000-0000-0000-0000-000000000001'
$subscriptionId = [guid]'00000000-0000-0000-0000-000000000002'
$tenantId = [guid]'00000000-0000-0000-0000-000000000003'
$capacityId = [guid]'00000000-0000-0000-0000-000000000004'
$databaseId = [guid]'00000000-0000-0000-0000-000000000005'
$bronzeId = [guid]'00000000-0000-0000-0000-000000000006'
$global:MacawShortcutTest = $null

function Reset-Fixture {
    $global:MacawShortcutTest = @{
        Shortcuts = [Collections.Generic.List[object]]::new()
        Folder = $false
        FolderType = 'directory'
        Posts = 0
        Puts = 0
        CapacityState = 'Active'
        MissingSource = ''
        Collision = ''
        TokenAudience = 'https://storage.azure.com/'
        PostStatus = 201
    }
}

function az {
    $audience = if ($args -contains 'https://storage.azure.com/') {
        $global:MacawShortcutTest.TokenAudience
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
            value = @([pscustomobject]@{ id = $capacityId.ToString(); state = $global:MacawShortcutTest.CapacityState })
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/items") {
        return [pscustomobject]@{
            value = @(
                [pscustomobject]@{ id = $databaseId.ToString(); type = 'SQLDatabase'; displayName = 'MacawEducation' }
                [pscustomobject]@{ id = $bronzeId.ToString(); type = 'Lakehouse'; displayName = 'MacawEducationBronze' }
            )
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/lakehouses/$bronzeId") {
        return [pscustomobject]@{
            id = $bronzeId.ToString()
            workspaceId = $workspaceId.ToString()
            description = 'Macaw education PoC Bronze lakehouse.'
            properties = [pscustomobject]@{
                defaultSchema = 'dbo'
                oneLakeFilesPath = "https://onelake.dfs.fabric.microsoft.com/$workspaceId/$bronzeId/Files"
                sqlEndpointProperties = [pscustomobject]@{ provisioningStatus = 'Success' }
            }
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/items/$bronzeId/shortcuts") {
        return [pscustomobject]@{ value = @($global:MacawShortcutTest.Shortcuts.ToArray()) }
    }
    throw "Unexpected fixture GET: $path"
}

function Invoke-WebRequest {
    param([string]$Method, [string]$Uri, $Headers, [string]$ContentType, [string]$Body, [switch]$SkipHttpErrorCheck)
    $path = ([uri]$Uri).AbsolutePath
    if ($Method -eq 'Head') {
        if ($path -eq "/$workspaceId/$bronzeId/Files/sql_mirror") {
            $status = if ($global:MacawShortcutTest.Folder) { 200 } else { 404 }
            return [pscustomobject]@{
                StatusCode = $status
                Headers = @{ 'x-ms-resource-type' = $global:MacawShortcutTest.FolderType }
            }
        }
        if ($path -match "/$workspaceId/$databaseId/Tables/dbo/([^/]+)/_delta_log$") {
            $status = if ($Matches[1] -eq $global:MacawShortcutTest.MissingSource) { 404 } else { 200 }
            return [pscustomobject]@{ StatusCode = $status; Headers = @{} }
        }
        if ($path -match "/$workspaceId/$bronzeId/Files/sql_mirror/([^/]+)/_delta_log$") {
            $name = $Matches[1]
            $found = @($global:MacawShortcutTest.Shortcuts | Where-Object name -ceq $name)
            $status = if ($found.Count -eq 1) { 200 } else { 404 }
            return [pscustomobject]@{ StatusCode = $status; Headers = @{} }
        }
        if ($path -match "/$workspaceId/$bronzeId/Files/sql_mirror/([^/]+)$") {
            $status = if ($Matches[1] -eq $global:MacawShortcutTest.Collision) { 200 } else { 404 }
            return [pscustomobject]@{ StatusCode = $status; Headers = @{} }
        }
    }
    if ($Method -eq 'Put' -and $path -eq "/$workspaceId/$bronzeId/Files/sql_mirror") {
        if ($Headers['If-None-Match'] -ne '*' -or $global:MacawShortcutTest.Folder) {
            throw 'Folder creation was not protected against an existing path.'
        }
        $global:MacawShortcutTest.Puts++
        $global:MacawShortcutTest.Folder = $true
        return [pscustomobject]@{ StatusCode = 201; Headers = @{} }
    }
    if ($Method -eq 'Post' -and $path -eq "/v1/workspaces/$workspaceId/items/$bronzeId/shortcuts") {
        Assert-FabricHeader $Headers
        $request = $Body | ConvertFrom-Json
        if ($request.path -ne 'Files/sql_mirror' -or
            $request.name -cnotin $contract.tables.name -or
            $request.target.oneLake.path -cne "Tables/dbo/$($request.name)") {
            throw 'The shortcut creation request is not allowlisted.'
        }
        $global:MacawShortcutTest.Posts++
        if ($global:MacawShortcutTest.PostStatus -eq 201) {
            $request.path = "/$($request.path)"
            $global:MacawShortcutTest.Shortcuts.Add($request)
        }
        return [pscustomobject]@{ StatusCode = $global:MacawShortcutTest.PostStatus; Headers = @{} }
    }
    throw "Unexpected fixture request: $Method $path"
}

function Invoke-Deployment {
    param([switch]$VerifyOnly)
    & $deployment -SubscriptionId $subscriptionId -TenantId $tenantId `
        -WorkspaceId $workspaceId -DatabaseItemId $databaseId -VerifyOnly:$VerifyOnly
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
    if ($global:MacawShortcutTest.Posts -ne 20 -or $global:MacawShortcutTest.Puts -ne 1) {
        throw 'Expected one directory and twenty shortcuts.'
    }
    Invoke-Deployment -VerifyOnly
    Invoke-Deployment
    if ($global:MacawShortcutTest.Posts -ne 20 -or $global:MacawShortcutTest.Puts -ne 1) {
        throw 'Verification or rerunning changed existing shortcuts.'
    }

    Reset-Fixture
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'missing in verify-only mode'
    if ($global:MacawShortcutTest.Posts -ne 0 -or $global:MacawShortcutTest.Puts -ne 0) {
        throw 'Verify-only mode created a path.'
    }

    Reset-Fixture
    $global:MacawShortcutTest.MissingSource = 'Student'
    Assert-Throws { Invoke-Deployment } "Delta log for 'Student' is not accessible"
    if ($global:MacawShortcutTest.Posts -ne 0 -or $global:MacawShortcutTest.Puts -ne 0) {
        throw 'A path was created despite a missing source table.'
    }

    Reset-Fixture
    $global:MacawShortcutTest.Folder = $true
    $global:MacawShortcutTest.Collision = 'Student'
    Assert-Throws { Invoke-Deployment } "already exists or cannot be inspected for 'Student'"
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'A conflicting path was not detected before creation.' }

    Reset-Fixture
    $global:MacawShortcutTest.Folder = $true
    $global:MacawShortcutTest.Shortcuts.Add([pscustomobject]@{
        path = '/Files/sql_mirror'; name = 'Campus'
        target = [pscustomobject]@{
            oneLake = [pscustomobject]@{
                workspaceId = $workspaceId.ToString(); itemId = $databaseId.ToString()
                path = 'Tables/dbo/Student'
            }
        }
    })
    Assert-Throws { Invoke-Deployment } "points to an unexpected or delegated target"
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'A mismatched shortcut was not detected before creation.' }

    Reset-Fixture
    $global:MacawShortcutTest.Folder = $true
    $global:MacawShortcutTest.Shortcuts.Add([pscustomobject]@{
        path = '/Files/sql_mirror'; name = 'SecurityAccessGrant'; target = [pscustomobject]@{}
    })
    Assert-Throws { Invoke-Deployment } 'outside the reviewed table contract'
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'An unexpected shortcut was not detected before creation.' }

    Reset-Fixture
    $global:MacawShortcutTest.Folder = $true
    $global:MacawShortcutTest.Shortcuts.Add([pscustomobject]@{
        path = '/Files'; name = 'sql_mirror'; target = [pscustomobject]@{}
    })
    Assert-Throws { Invoke-Deployment } 'outside the reviewed table contract'
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'An ancestor shortcut was not detected before creation.' }

    Reset-Fixture
    $global:MacawShortcutTest.Folder = $true
    $global:MacawShortcutTest.Shortcuts.Add([pscustomobject]@{
        path = '/Files/sql_mirror/nested'; name = 'unreviewed'; target = [pscustomobject]@{}
    })
    Assert-Throws { Invoke-Deployment } 'outside the reviewed table contract'
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'A nested shortcut was not detected before creation.' }

    Reset-Fixture
    $global:MacawShortcutTest.Folder = $true
    $global:MacawShortcutTest.Shortcuts.Add([pscustomobject]@{
        path = '/Files/sql_mirror'; name = 'Campus'
        target = [pscustomobject]@{
            oneLake = [pscustomobject]@{
                workspaceId = $workspaceId.ToString(); itemId = $databaseId.ToString()
                path = 'Tables/dbo/Campus'; connectionId = 'delegated-connection'
            }
        }
    })
    Assert-Throws { Invoke-Deployment } 'unexpected or delegated target'
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'A delegated shortcut was accepted.' }

    Reset-Fixture
    $global:MacawShortcutTest.Folder = $true
    $global:MacawShortcutTest.FolderType = 'file'
    Assert-Throws { Invoke-Deployment } 'not a directory'
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'A file was accepted as the landing directory.' }

    Reset-Fixture
    $global:MacawShortcutTest.CapacityState = 'Paused'
    Assert-Throws { Invoke-Deployment } 'not uniquely visible and active'
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'A shortcut was created on a paused capacity.' }

    Reset-Fixture
    $global:MacawShortcutTest.TokenAudience = 'https://wrong.example/'
    Assert-Throws { Invoke-Deployment } 'different tenant or audience'
    if ($global:MacawShortcutTest.Posts -ne 0) { throw 'A shortcut was created with the wrong audience.' }

    Reset-Fixture
    $global:MacawShortcutTest.PostStatus = 200
    Assert-Throws { Invoke-Deployment } 'was not created: HTTP 200'
    if ($global:MacawShortcutTest.Posts -ne 1) { throw 'Deployment continued after an unexpected POST result.' }
} finally {
    Remove-Variable -Name MacawShortcutTest -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'SQL Bronze shortcut deployment tests passed.'
