import base64
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from foundry_agent import select_data_agent_server, token_tenant, verify_connection


WORKSPACE = "11111111-1111-4111-8111-111111111111"
AGENT = "22222222-2222-4222-8222-222222222222"
URL = f"https://api.fabric.microsoft.com/v1/mcp/workspaces/{WORKSPACE}/dataagents/{AGENT}/agent"
AUDIENCE = "https://api.fabric.microsoft.com/"


class FoundryAgentTests(unittest.TestCase):
    def test_selects_only_the_discovered_data_agent_server(self) -> None:
        discovery = {
            "items": [
                {
                    "engines": [
                        {
                            "mcpServers": [
                                {"name": "microsoft.fabric.oneLake", "url": "https://example.com"},
                                {
                                    "name": "Data Agent MCP",
                                    "url": URL + "?example=1",
                                    "auth": {"audience": AUDIENCE},
                                },
                            ]
                        }
                    ]
                }
            ]
        }
        self.assertEqual(select_data_agent_server(discovery, WORKSPACE, AGENT), (URL + "?example=1", AUDIENCE))
        discovery["items"][0]["engines"][0]["mcpServers"][1]["url"] = URL.replace(
            "api.fabric.microsoft.com", "untrusted.example"
        )
        with self.assertRaises(RuntimeError):
            select_data_agent_server(discovery, WORKSPACE, AGENT)

    def test_reuses_only_matching_private_delegated_connections(self) -> None:
        connection = {
            "name": "example",
            "id": "/connections/example",
            "properties": {
                "category": "RemoteTool",
                "authType": "UserEntraToken",
                "target": URL,
                "audience": AUDIENCE,
                "isSharedToAll": False,
            },
        }
        self.assertEqual(verify_connection(connection, URL, AUDIENCE), "/connections/example")
        connection["properties"]["isSharedToAll"] = True
        with self.assertRaises(RuntimeError):
            verify_connection(connection, URL, AUDIENCE)

    def test_reads_the_tenant_claim(self) -> None:
        payload = base64.urlsafe_b64encode(json.dumps({"tid": "expected-tenant"}).encode()).decode().rstrip("=")
        self.assertEqual(token_tenant(f"header.{payload}.signature"), "expected-tenant")


if __name__ == "__main__":
    unittest.main()
