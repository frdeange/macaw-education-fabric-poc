function Get-FabricHeaders {
    param([guid]$SubscriptionId, [guid]$TenantId)

    $token = & az account get-access-token --subscription $SubscriptionId.ToString() `
        --resource 'https://api.fabric.microsoft.com' --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw 'Unable to acquire a Fabric access token for the selected subscription.'
    }

    $claimsPart = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $claimsPart = $claimsPart.PadRight($claimsPart.Length + ((4 - $claimsPart.Length % 4) % 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($claimsPart)) | ConvertFrom-Json
    if ($claims.tid -ne $TenantId.ToString()) {
        throw 'The Fabric access token belongs to a different tenant.'
    }

    return @{
        Authorization = "Bearer $token"
        'x-ms-fabric-skill' = 'semantic-model-authoring'
    }
}

function Assert-SemanticModelDeploymentAllowed {
    param([string]$ModelRoot)

    if (Test-Path -LiteralPath (Join-Path $ModelRoot 'DEPLOYMENT_BLOCKED')) {
        throw 'Semantic-model deployment is blocked pending campus-department security validation.'
    }
}

function Get-FabricItems {
    param([string]$Uri, [hashtable]$Headers)

    $next = $Uri
    do {
        $resolved = [Uri]::new([Uri]'https://api.fabric.microsoft.com', $next)
        if ($resolved.Scheme -ne 'https' -or $resolved.Host -ne 'api.fabric.microsoft.com') {
            throw 'Fabric returned an unexpected continuation URL.'
        }
        $page = Invoke-RestMethod -Uri $resolved.AbsoluteUri -Headers $Headers
        $page.value
        if ($page.PSObject.Properties.Name -contains 'continuationUri' -and $page.continuationUri) {
            $next = $page.continuationUri
        } elseif ($page.PSObject.Properties.Name -contains 'continuationToken' -and $page.continuationToken) {
            throw 'Fabric returned a continuation token without a continuation URL.'
        } else {
            $next = $null
        }
    } while ($next)
}

function Wait-FabricOperation {
    param($Response, [hashtable]$Headers)

    $operationId = [string]@($Response.Headers['x-ms-operation-id'])[0]
    $operationGuid = [Guid]::Empty
    if (-not [Guid]::TryParse($operationId, [ref]$operationGuid)) {
        throw 'The operation was accepted without a valid ID. Inspect the item before retrying.'
    }
    $operationUri = "https://api.fabric.microsoft.com/v1/operations/$operationGuid"
    $retryAfter = [string]@($Response.Headers['Retry-After'])[0]
    $delay = if ($retryAfter -match '^\d+$') { [int]$retryAfter } else { 15 }
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Seconds ([Math]::Max(1, $delay))
        $operationResponse = Invoke-WebRequest -Uri $operationUri -Headers $Headers
        $operation = $operationResponse.Content | ConvertFrom-Json
        Write-Host "Fabric operation: $($operation.status)"
        if ($operation.status -eq 'Succeeded') {
            return
        }
        if ($operation.status -in @('Failed', 'Cancelled')) {
            throw "Fabric operation $($operation.status): $($operationResponse.Content)"
        }
        $retryAfter = [string]@($operationResponse.Headers['Retry-After'])[0]
        if ($retryAfter -match '^\d+$') {
            $delay = [int]$retryAfter
        }
    }
    throw "Operation is still pending at $operationUri. Inspect it before retrying."
}
