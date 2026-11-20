$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function az {
    throw 'Azure CLI must not be called for a blocked deployment.'
}

function Assert-Blocked {
    param([scriptblock]$Action)

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -like '*blocked pending campus-department security validation*') {
            return
        }
        throw
    }
    throw 'The semantic-model deployment was not blocked.'
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("macaw-model-gate-" + [guid]::NewGuid())
$fixtureScripts = Join-Path $fixture 'scripts'
$fixtureModel = Join-Path $fixture 'semantic-model'
$marker = Join-Path $fixtureModel 'DEPLOYMENT_BLOCKED'
$scriptNames = @('fabric-api.ps1', 'deploy-semantic-model.ps1', 'update-semantic-model.ps1')

New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    New-Item -ItemType Directory -Path $fixtureScripts, $fixtureModel | Out-Null
    foreach ($name in $scriptNames) {
        Copy-Item -LiteralPath (Join-Path $root "scripts\$name") -Destination $fixtureScripts
    }
    . (Join-Path $fixtureScripts 'fabric-api.ps1')
    Assert-SemanticModelDeploymentAllowed -ModelRoot $fixtureModel

    New-Item -ItemType File -Path $marker | Out-Null
    Assert-Blocked { Assert-SemanticModelDeploymentAllowed -ModelRoot $fixtureModel }

    $id = [guid]'00000000-0000-0000-0000-000000000001'
    Assert-Blocked {
        & (Join-Path $fixtureScripts 'deploy-semantic-model.ps1') `
            -SubscriptionId $id -TenantId $id -WorkspaceId $id -DatabaseItemId $id
    }
    Assert-Blocked {
        & (Join-Path $fixtureScripts 'update-semantic-model.ps1') `
            -SubscriptionId $id -TenantId $id -WorkspaceId $id -SemanticModelId $id `
            -BaselineDefinitionPath 'unused.json' -PartPaths 'definition/tables/Learner.tmdl'
    }
} finally {
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker }
    foreach ($name in $scriptNames) {
        $file = Join-Path $fixtureScripts $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    foreach ($directory in @($fixtureScripts, $fixtureModel, $fixture)) {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
    }
}

Write-Host 'Semantic-model deployment gate tests passed.'
