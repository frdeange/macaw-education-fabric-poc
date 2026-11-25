$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$deployment = Join-Path $root 'scripts\deploy-sql-bronze-shortcuts.ps1'
$workspaceId = [guid]'00000000-0000-0000-0000-000000000001'
$subscriptionId = [guid]'00000000-0000-0000-0000-000000000002'
$tenantId = [guid]'00000000-0000-0000-0000-000000000003'
$capacityId = [guid]'00000000-0000-0000-0000-000000000004'
$databaseId = [guid]'00000000-0000-0000-0000-000000000005'
$bronzeId = [guid]'00000000-0000-0000-0000-000000000006'
$global:MacawShortcutTest = $null

function Reset-Fixture {
    $shortcuts = [Collections.Generic.List[object]]::new()
    $shortcuts.Add([pscustomobject]@{
        path = '/Tables'; name = 'sql'
        target = [pscustomobject]@{
            oneLake = [pscustomobject]@{
                workspaceId = $workspaceId.ToString(); itemId = $databaseId.ToString()
                path = 'Tables/dbo'
            }
        }
    })
    $global:MacawShortcutTest = @{
        Shortcuts = $shortcuts
        Writes = 0
        CapacityState = 'Active'
        MissingSource = ''
        MissingBronze = ''
        TokenAudience = 'https://storage.azure.com/'
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

function Invoke-RestMethod {
    param([string]$Uri, $Headers)
    if ($Headers['x-ms-fabric-skill'] -ne 'e2e-medallion-architecture') {
        throw 'Missing Fabric skill attribution.'
    }
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
            id = $bronzeId.ToString(); workspaceId = $workspaceId.ToString()
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
    param([string]$Method, [string]$Uri, $Headers, [switch]$SkipHttpErrorCheck)
    if ($Method -ne 'Head') {
        $global:MacawShortcutTest.Writes++
        throw "Unexpected write: $Method"
    }
    $path = ([uri]$Uri).AbsolutePath
    if ($path -match "/$workspaceId/$databaseId/Tables/dbo/([^/]+)/_delta_log$") {
        $status = if ($Matches[1] -eq $global:MacawShortcutTest.MissingSource) { 404 } else { 200 }
        return [pscustomobject]@{ StatusCode = $status; Headers = @{} }
    }
    if ($path -match "/$workspaceId/$bronzeId/Tables/sql/([^/]+)/_delta_log$") {
        $status = if ($Matches[1] -eq $global:MacawShortcutTest.MissingBronze) { 404 } else { 200 }
        return [pscustomobject]@{ StatusCode = $status; Headers = @{} }
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
    Assert-Throws { Invoke-Deployment } 'legacy Files shortcuts is retired'
    Invoke-Deployment -VerifyOnly
    if ($global:MacawShortcutTest.Writes -ne 0) { throw 'Verification attempted a write.' }

    Reset-Fixture
    $global:MacawShortcutTest.Shortcuts.Clear()
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'schema shortcut is missing or ambiguous'

    Reset-Fixture
    $global:MacawShortcutTest.Shortcuts.Add($global:MacawShortcutTest.Shortcuts[0])
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'schema shortcut is missing or ambiguous'

    Reset-Fixture
    $global:MacawShortcutTest.Shortcuts[0].target.oneLake.path = 'Tables/dbo/Student'
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'unexpected or delegated target'

    Reset-Fixture
    $global:MacawShortcutTest.Shortcuts[0].target.oneLake |
        Add-Member -NotePropertyName connectionId -NotePropertyValue 'delegated-connection'
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'unexpected or delegated target'

    Reset-Fixture
    $global:MacawShortcutTest.Shortcuts.Add([pscustomobject]@{
        path = '/Files/sql_mirror'; name = 'Student'; target = [pscustomobject]@{}
    })
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'Legacy SQL Files shortcuts still exist'

    Reset-Fixture
    $global:MacawShortcutTest.MissingSource = 'Student'
    Assert-Throws { Invoke-Deployment -VerifyOnly } "Delta log for 'Student' is not accessible"

    Reset-Fixture
    $global:MacawShortcutTest.MissingBronze = 'Student'
    Assert-Throws { Invoke-Deployment -VerifyOnly } "Shortcut 'Student' cannot read its Delta log"

    Reset-Fixture
    $global:MacawShortcutTest.CapacityState = 'Paused'
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'not uniquely visible and active'

    Reset-Fixture
    $global:MacawShortcutTest.TokenAudience = 'https://wrong.example/'
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'different tenant or audience'
} finally {
    Remove-Variable -Name MacawShortcutTest -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'SQL Bronze schema shortcut verification tests passed.'
