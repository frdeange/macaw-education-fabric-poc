import base64
import json
from typing import Any
from uuid import UUID

from azure.core.credentials import AccessToken
from azure.identity import AzureCliCredential


def guid(value: str) -> str:
    return str(UUID(value))


def token_tenant(token: str) -> str:
    payload = token.split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    return claims["tid"]


class TenantCheckedCredential:
    def __init__(self, subscription_id: str, tenant_id: str) -> None:
        self.tenant_id = tenant_id
        self.credential = AzureCliCredential(subscription=subscription_id)

    def get_token(self, *scopes: str, **kwargs: Any) -> AccessToken:
        requested_tenant = kwargs.pop("tenant_id", None)
        if requested_tenant and requested_tenant.lower() != self.tenant_id.lower():
            raise RuntimeError("The requested token tenant does not match the project tenant.")
        token = self.credential.get_token(*scopes, **kwargs)
        if token_tenant(token.token).lower() != self.tenant_id.lower():
            raise RuntimeError("The acquired token belongs to a different tenant.")
        return token

    def close(self) -> None:
        self.credential.close()
