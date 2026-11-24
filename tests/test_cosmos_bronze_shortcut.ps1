$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$deployment = Join-Path $root 'scripts\deploy-cosmos-bronze-shortcut.ps1'
$workspaceId = [guid]'00000000-0000-0000-0000-000000000001'
$subscriptionId = [guid]'00000000-0000-0000-0000-000000000002'
$tenantId = [guid]'00000000-0000-0000-0000-000000000003'
$databaseId = [guid]'00000000-0000-0000-0000-000000000005'
$bronzeId = [guid]'00000000-0000-0000-0000-000000000006'
$global:MacawCosmosShortcutTest = $null

function Reset-Fixture {
    $shortcuts = [Collections.Generic.List[object]]::new()
    $shortcuts.Add([pscustomobject]@{
        path = '/Tables'; name = 'CosmosDB'
        target = [pscustomobject]@{
            oneLake = [pscustomobject]@{
                workspaceId = $workspaceId.ToString(); itemId = $databaseId.ToString()
                path = 'Tables/MacawFacilitiesIncidents'
            }
        }
    })
    $global:MacawCosmosShortcutTest = @{
        Shortcuts = $shortcuts
        Writes = 0
        MissingSource = $false
        MissingBronze = $false
    }
}

function az {
    $audience = if ($args -contains 'https://storage.azure.com/') {
        'https://storage.azure.com/'
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
    if ($path -eq "/v1/workspaces/$workspaceId/cosmosDbDatabases") {
        return [pscustomobject]@{
            value = @([pscustomobject]@{
                id = $databaseId.ToString(); displayName = 'MacawFacilitiesIncidents'
                description = 'Macaw education PoC synthetic facilities incidents.'
            })
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/items") {
        return [pscustomobject]@{
            value = @([pscustomobject]@{
                id = $bronzeId.ToString(); type = 'Lakehouse'; displayName = 'MacawEducationBronze'
            })
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/cosmosDbDatabases/$databaseId") {
        return [pscustomobject]@{
            id = $databaseId.ToString(); workspaceId = $workspaceId.ToString()
            properties = [pscustomobject]@{ databaseName = 'MacawFacilitiesIncidents' }
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
        return [pscustomobject]@{ value = @($global:MacawCosmosShortcutTest.Shortcuts.ToArray()) }
    }
    throw "Unexpected fixture GET: $path"
}

function Invoke-WebRequest {
    param([string]$Method, [string]$Uri, $Headers, [switch]$SkipHttpErrorCheck)
    if ($Method -ne 'Head') {
        $global:MacawCosmosShortcutTest.Writes++
        throw "Unexpected write: $Method"
    }
    $path = ([uri]$Uri).AbsolutePath
    if ($path -eq "/$workspaceId/$databaseId/Tables/MacawFacilitiesIncidents/FacilityIncidents/_delta_log") {
        $status = if ($global:MacawCosmosShortcutTest.MissingSource) { 404 } else { 200 }
        return [pscustomobject]@{ StatusCode = $status; Headers = @{} }
    }
    if ($path -eq "/$workspaceId/$bronzeId/Tables/CosmosDB/FacilityIncidents/_delta_log") {
        $status = if ($global:MacawCosmosShortcutTest.MissingBronze) { 404 } else { 200 }
        return [pscustomobject]@{ StatusCode = $status; Headers = @{} }
    }
    throw "Unexpected fixture request: $Method $path"
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
    Assert-Throws { Invoke-Deployment } 'legacy Files shortcut is retired'
    Invoke-Deployment -VerifyOnly
    if ($global:MacawCosmosShortcutTest.Writes -ne 0) { throw 'Verification attempted a write.' }

    Reset-Fixture
    $global:MacawCosmosShortcutTest.Shortcuts.Clear()
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'schema shortcut is missing or ambiguous'

    Reset-Fixture
    $global:MacawCosmosShortcutTest.Shortcuts[0].target.oneLake.path = 'Tables/OtherDatabase'
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'unexpected or delegated target'

    Reset-Fixture
    $global:MacawCosmosShortcutTest.Shortcuts.Add([pscustomobject]@{
        path = '/Files/cosmos_mirror'; name = 'FacilityIncidents'; target = [pscustomobject]@{}
    })
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'Legacy Cosmos Files shortcuts still exist'

    Reset-Fixture
    $global:MacawCosmosShortcutTest.MissingSource = $true
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'mirrored Cosmos Delta log is not accessible'

    Reset-Fixture
    $global:MacawCosmosShortcutTest.MissingBronze = $true
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'Cosmos shortcut cannot read its Delta log'
} finally {
    Remove-Variable -Name MacawCosmosShortcutTest -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Cosmos Bronze schema shortcut verification tests passed.'
