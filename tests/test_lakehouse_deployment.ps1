$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$deployment = Join-Path $root 'scripts\deploy-lakehouses.ps1'
$workspaceId = [guid]'00000000-0000-0000-0000-000000000001'
$subscriptionId = [guid]'00000000-0000-0000-0000-000000000002'
$tenantId = [guid]'00000000-0000-0000-0000-000000000003'
$capacityId = [guid]'00000000-0000-0000-0000-000000000004'
$global:MacawLakehouseTest = $null

function Reset-Fixture {
    $global:MacawLakehouseTest = @{
        Items = [Collections.Generic.List[object]]::new()
        Posts = 0
        Operations = 0
        Async = $false
        OperationState = 'Succeeded'
        CapacityState = 'Active'
        EndpointState = 'Success'
    }
}

function az {
    $claims = @{ tid = $tenantId.ToString() } | ConvertTo-Json -Compress
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).
        TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $global:LASTEXITCODE = 0
    "header.$payload.signature"
}

function Assert-SkillHeader {
    param($Headers)
    if ($Headers['x-ms-fabric-skill'] -ne 'e2e-medallion-architecture') {
        throw 'Missing Fabric skill attribution.'
    }
}

function Invoke-RestMethod {
    param([string]$Uri, $Headers)
    Assert-SkillHeader $Headers
    $path = ([uri]$Uri).AbsolutePath
    if ($path -eq '/v1/workspaces') {
        return [pscustomobject]@{
            value = @([pscustomobject]@{ id = $workspaceId.ToString(); capacityId = $capacityId.ToString() })
        }
    }
    if ($path -eq '/v1/capacities') {
        return [pscustomobject]@{
            value = @([pscustomobject]@{ id = $capacityId.ToString(); state = $global:MacawLakehouseTest.CapacityState })
        }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/items") {
        return [pscustomobject]@{ value = @($global:MacawLakehouseTest.Items.ToArray()) }
    }
    if ($path -eq "/v1/workspaces/$workspaceId/lakehouses") {
        return [pscustomobject]@{
            value = @($global:MacawLakehouseTest.Items | Where-Object type -eq 'Lakehouse')
        }
    }
    if ($path -match "/v1/workspaces/$workspaceId/lakehouses/([^/]+)$") {
        $item = @($global:MacawLakehouseTest.Items | Where-Object id -eq $Matches[1])
        if ($item.Count -ne 1) { throw 'Fixture item not found.' }
        $endpointId = if ($item[0].PSObject.Properties['EndpointId']) { $item[0].EndpointId } else { 'endpoint' }
        $properties = @{
            oneLakeFilesPath = 'https://example.invalid/Files'
            oneLakeTablesPath = 'https://example.invalid/Tables'
            sqlEndpointProperties = [pscustomobject]@{
                id = $endpointId
                connectionString = 'example.invalid'
                provisioningStatus = $global:MacawLakehouseTest.EndpointState
            }
        }
        if ($item[0].SchemaEnabled) { $properties.defaultSchema = 'dbo' }
        return [pscustomobject]@{
            id = $item[0].id
            workspaceId = $workspaceId.ToString()
            displayName = $item[0].displayName
            description = $item[0].description
            type = $item[0].type
            properties = [pscustomobject]$properties
        }
    }
    throw "Unexpected fixture GET: $path"
}

function Invoke-WebRequest {
    param([string]$Method, [string]$Uri, $Headers, [string]$ContentType, [string]$Body)
    Assert-SkillHeader $Headers
    $path = ([uri]$Uri).AbsolutePath
    if ($Method -eq 'Post' -and $path -eq "/v1/workspaces/$workspaceId/lakehouses") {
        $request = $Body | ConvertFrom-Json
        if (-not $request.creationPayload.enableSchemas) { throw 'Schemas were not enabled.' }
        $global:MacawLakehouseTest.Posts++
        $endpointId = [guid]::NewGuid().ToString()
        $global:MacawLakehouseTest.Items.Add([pscustomobject]@{
            id = [guid]::NewGuid().ToString()
            displayName = $request.displayName
            description = $request.description
            type = 'Lakehouse'
            SchemaEnabled = $true
            EndpointId = $endpointId
        })
        $global:MacawLakehouseTest.Items.Add([pscustomobject]@{
            id = $endpointId
            displayName = $request.displayName
            description = $request.description
            type = 'SQLEndpoint'
        })
        if ($global:MacawLakehouseTest.Async) {
            return [pscustomobject]@{
                StatusCode = 202
                Headers = @{ 'x-ms-operation-id' = '00000000-0000-0000-0000-000000000005'; 'Retry-After' = '1' }
            }
        }
        return [pscustomobject]@{ StatusCode = 201; Headers = @{} }
    }
    if ($path -match '^/v1/operations/') {
        $global:MacawLakehouseTest.Operations++
        $content = @{ status = $global:MacawLakehouseTest.OperationState } | ConvertTo-Json -Compress
        return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = $content }
    }
    throw "Unexpected fixture request: $Method $path"
}

function Start-Sleep { param([int]$Seconds) }

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
    if ($global:MacawLakehouseTest.Posts -ne 3) { throw 'Expected three create requests.' }
    Invoke-Deployment -VerifyOnly
    if ($global:MacawLakehouseTest.Posts -ne 3) { throw 'Verification created another item.' }
    Invoke-Deployment
    if ($global:MacawLakehouseTest.Posts -ne 3) { throw 'Rerunning created another item.' }
    $global:MacawLakehouseTest.Items.Add([pscustomobject]@{
        id = [guid]::NewGuid().ToString(); displayName = 'MacawEducationSilver'
        description = 'Unrelated'; type = 'Notebook'
    })
    Assert-Throws { Invoke-Deployment } 'also used by an unrelated item'
    if ($global:MacawLakehouseTest.Posts -ne 3) { throw 'A conflicting item was not checked before creation.' }

    Reset-Fixture
    Assert-Throws { Invoke-Deployment -VerifyOnly } 'missing in verify-only mode'
    if ($global:MacawLakehouseTest.Posts -ne 0) { throw 'Verify-only mode created an item.' }

    Reset-Fixture
    $global:MacawLakehouseTest.Items.Add([pscustomobject]@{
        id = [guid]::NewGuid().ToString(); displayName = 'MacawEducationSilver'
        description = 'Unrelated'; type = 'Notebook'; SchemaEnabled = $false
    })
    Assert-Throws { Invoke-Deployment } 'belongs to another item type'
    if ($global:MacawLakehouseTest.Posts -ne 0) { throw 'A conflicting item was not checked before creation.' }

    Reset-Fixture
    $global:MacawLakehouseTest.Items.Add([pscustomobject]@{
        id = [guid]::NewGuid().ToString(); displayName = 'MacawEducationSilver'
        description = 'Unrelated'; type = 'Lakehouse'; SchemaEnabled = $true
    })
    Assert-Throws { Invoke-Deployment } 'does not match the expected project item'
    if ($global:MacawLakehouseTest.Posts -ne 0) { throw 'An unrelated item was not checked before creation.' }

    Reset-Fixture
    $global:MacawLakehouseTest.Items.Add([pscustomobject]@{
        id = [guid]::NewGuid().ToString(); displayName = 'MacawEducationSilver'
        description = 'Macaw education PoC Silver lakehouse.'; type = 'Lakehouse'; SchemaEnabled = $false
    })
    Assert-Throws { Invoke-Deployment } 'not schema-enabled'
    if ($global:MacawLakehouseTest.Posts -ne 0) { throw 'An incompatible item was not checked before creation.' }

    Reset-Fixture
    $global:MacawLakehouseTest.Async = $true
    Invoke-Deployment
    if ($global:MacawLakehouseTest.Posts -ne 3 -or $global:MacawLakehouseTest.Operations -ne 3) {
        throw 'Asynchronous create operations were not awaited.'
    }

    Reset-Fixture
    $global:MacawLakehouseTest.Async = $true
    $global:MacawLakehouseTest.OperationState = 'Failed'
    Assert-Throws { Invoke-Deployment } 'Fabric operation Failed'
    if ($global:MacawLakehouseTest.Posts -ne 1) { throw 'Deployment continued after a failed operation.' }

    Reset-Fixture
    $global:MacawLakehouseTest.EndpointState = 'Failed'
    Assert-Throws { Invoke-Deployment } 'failed to provision'
    if ($global:MacawLakehouseTest.Posts -ne 1) { throw 'Deployment continued after an endpoint failed.' }

    Reset-Fixture
    $global:MacawLakehouseTest.EndpointState = 'InProgress'
    Assert-Throws { Invoke-Deployment } 'not ready'
    if ($global:MacawLakehouseTest.Posts -ne 1) { throw 'Deployment continued after an endpoint timed out.' }

    Reset-Fixture
    $global:MacawLakehouseTest.CapacityState = 'Paused'
    Assert-Throws { Invoke-Deployment } 'not uniquely visible and active'
    if ($global:MacawLakehouseTest.Posts -ne 0) { throw 'A lakehouse was created on an inactive capacity.' }
} finally {
    Remove-Variable -Name MacawLakehouseTest -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Lakehouse deployment tests passed.'
