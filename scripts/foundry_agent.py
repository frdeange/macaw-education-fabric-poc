import argparse
import http.client
import json
import sys
import time
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import FabricIQPreviewTool, PromptAgentDefinition
from azure.core.exceptions import ResourceNotFoundError

from azure_auth import TenantCheckedCredential, guid, token_tenant


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "fabric" / "foundry-agent.json"
ARM_API_VERSION = "2025-10-01-preview"


def request_json(
    method: str,
    url: str,
    token: str,
    *,
    body: dict[str, Any] | None = None,
    missing_ok: bool = False,
) -> dict[str, Any] | None:
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in {"management.azure.com", "onelake.table.fabric.microsoft.com"}
        or parsed.username
        or parsed.password
        or parsed.port not in (None, 443)
        or parsed.fragment
    ):
        raise ValueError("Unexpected management or discovery URL.")
    path = parsed.path + (f"?{parsed.query}" if parsed.query else "")
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
        headers["If-None-Match"] = "*"
    connection = http.client.HTTPSConnection(parsed.hostname, timeout=60)
    try:
        connection.request(method, path, body=payload, headers=headers)
        response = connection.getresponse()
        content = response.read().decode("utf-8")
        if response.status == 404 and missing_ok:
            return None
        if response.status not in (200, 201):
            raise RuntimeError(f"{method} {parsed.path} failed ({response.status}): {content}")
        return json.loads(content)
    finally:
        connection.close()


def select_data_agent_server(
    discovery: dict[str, Any], workspace_id: str, agent_id: str
) -> tuple[str, str]:
    expected_path = f"/v1/mcp/workspaces/{workspace_id}/dataagents/{agent_id}/agent"
    matches = []
    for item in discovery.get("items", []):
        for engine in item.get("engines", []):
            for server in engine.get("mcpServers", []):
                url = server.get("url", "")
                parsed = urlsplit(url)
                if (
                    server.get("name") == "Data Agent MCP"
                    and parsed.scheme == "https"
                    and parsed.hostname == "api.fabric.microsoft.com"
                    and parsed.port in (None, 443)
                    and not parsed.username
                    and not parsed.password
                    and not parsed.fragment
                    and parsed.path.lower() == expected_path.lower()
                ):
                    audience = server.get("auth", {}).get("audience", "")
                    if audience.rstrip("/") not in {
                        "https://api.fabric.microsoft.com",
                        "https://analysis.windows.net/powerbi/api",
                    }:
                        raise RuntimeError("The discovered Data Agent audience is unexpected.")
                    matches.append((url, audience))
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one matching Data Agent MCP server.")
    return matches[0]


def verify_connection(connection: dict[str, Any], target: str, audience: str) -> str:
    properties = connection["properties"]
    expected = {
        "category": "RemoteTool",
        "authType": "UserEntraToken",
        "target": target,
        "audience": audience,
        "isSharedToAll": False,
    }
    if any(properties.get(key) != value for key, value in expected.items()):
        raise RuntimeError(
            f"Connection {connection.get('name')} differs from the intended delegated configuration."
        )
    return connection["id"]


def agent_config() -> dict[str, Any]:
    return json.loads(CONFIG.read_text(encoding="utf-8"))


def project_endpoint(account: str, project: str) -> str:
    if not account or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-" for c in account):
        raise ValueError("Invalid Foundry account name.")
    return f"https://{account}.services.ai.azure.com/api/projects/{quote(project, safe='')}"


def deploy(args: argparse.Namespace, credential: TenantCheckedCredential) -> None:
    config = agent_config()
    endpoint = project_endpoint(args.account, args.project)
    workspace_id = guid(args.workspace_id)
    agent_specs = [
        ("macaw-operations-iq", "school-operations", guid(args.operations_agent_id)),
        ("macaw-outcomes-iq", "learning-outcomes", guid(args.outcomes_agent_id)),
    ]
    arm_base = (
        f"https://management.azure.com/subscriptions/{guid(args.subscription_id)}"
        f"/resourceGroups/{quote(args.resource_group, safe='')}"
        f"/providers/Microsoft.CognitiveServices/accounts/{quote(args.account, safe='')}"
        f"/projects/{quote(args.project, safe='')}/connections"
    )
    storage_token = credential.get_token("https://storage.azure.com/.default").token
    arm_token = credential.get_token("https://management.azure.com/.default").token

    with AIProjectClient(endpoint=endpoint, credential=credential) as project:
        try:
            project.agents.get(config["name"])
        except ResourceNotFoundError:
            pass
        else:
            raise RuntimeError(
                f"Foundry agent {config['name']} already exists; inspect it before creating another version."
            )

        servers = []
        for name, label, agent_id in agent_specs:
            discovery_url = (
                "https://onelake.table.fabric.microsoft.com/api/v2/"
                f"{workspace_id}/{agent_id}/endpoints"
            )
            discovery = request_json("GET", discovery_url, storage_token)
            if discovery is None:
                raise RuntimeError("OneLake endpoint discovery returned no response.")
            server_url, audience = select_data_agent_server(discovery, workspace_id, agent_id)
            connection_url = f"{arm_base}/{name}?api-version={ARM_API_VERSION}"
            existing = request_json("GET", connection_url, arm_token, missing_ok=True)
            if existing is not None:
                verify_connection(existing, server_url, audience)
            servers.append((name, label, server_url, audience, connection_url, existing))

        tools = []
        for name, label, server_url, audience, connection_url, existing in servers:
            if existing is None:
                body = {
                    "properties": {
                        "category": "RemoteTool",
                        "authType": "UserEntraToken",
                        "target": server_url,
                        "audience": audience,
                        "isSharedToAll": False,
                    }
                }
                request_json("PUT", connection_url, arm_token, body=body)
                existing = request_json("GET", connection_url, arm_token)
                if existing is None:
                    raise RuntimeError(f"Connection {name} was not found after creation.")
            connection_id = verify_connection(existing, server_url, audience)
            tools.append(
                FabricIQPreviewTool(
                    project_connection_id=connection_id,
                    server_label=label,
                    server_url=server_url,
                    require_approval="never",
                )
            )
            print(f"Verified delegated connection: {name}")

        definition = PromptAgentDefinition(
            model=args.model,
            instructions="\n".join(config["instructions"]),
            tools=tools,
        )
        agent = project.agents.create_version(
            agent_name=config["name"],
            description=config["description"],
            definition=definition,
        )
        saved = project.agents.get_version(agent_name=agent.name, agent_version=agent.version)
        saved_tools = saved.definition.tools
        expected_tools = {(tool.server_label, tool.project_connection_id) for tool in tools}
        actual_tools = {(tool.server_label, tool.project_connection_id) for tool in saved_tools}
        if saved.definition.model != args.model or actual_tools != expected_tools:
            raise RuntimeError("The saved Foundry agent does not match the intended model and tools.")
        print(f"Created Foundry agent: {agent.name}, version {agent.version}")


def ask(args: argparse.Namespace, credential: TenantCheckedCredential) -> None:
    config = agent_config()
    endpoint = project_endpoint(args.account, args.project)
    with AIProjectClient(endpoint=endpoint, credential=credential) as project:
        agent = project.agents.get(config["name"])
        print(f"Invoking Foundry agent: {agent.name}")
        with project.get_openai_client(agent_name=agent.name) as client:
            response = client.responses.create(input=args.question, background=True)
            for _ in range(60):
                if response.status not in ("queued", "in_progress"):
                    break
                time.sleep(5)
                response = client.responses.retrieve(response.id)
            if response.status != "completed":
                raise RuntimeError(f"Foundry response did not complete: {response.status}; {response.error}")
            print("Output types:", ", ".join(item.type for item in response.output))
            for item in response.output:
                if item.type.startswith("mcp_"):
                    print("Tool activity:", item.model_dump_json(exclude_none=True))
            if not response.output_text:
                raise RuntimeError("Foundry returned no answer text.")
            print(response.output_text)


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Deploy or query the Macaw Foundry prompt agent.")
    parser.add_argument("--subscription-id", required=True, type=guid)
    parser.add_argument("--tenant-id", required=True, type=guid)
    parser.add_argument("--resource-group", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--project", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("deploy")
    create.add_argument("--workspace-id", required=True, type=guid)
    create.add_argument("--operations-agent-id", required=True, type=guid)
    create.add_argument("--outcomes-agent-id", required=True, type=guid)
    create.add_argument("--model", required=True)
    question = commands.add_parser("ask")
    question.add_argument("--question", required=True)
    args = parser.parse_args()
    credential = TenantCheckedCredential(args.subscription_id, args.tenant_id)
    try:
        if args.command == "deploy":
            deploy(args, credential)
        else:
            ask(args, credential)
    finally:
        credential.close()


if __name__ == "__main__":
    main()
