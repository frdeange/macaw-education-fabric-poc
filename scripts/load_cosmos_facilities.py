"""Load the reviewed synthetic incident snapshot into a Fabric Cosmos DB container."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from azure.cosmos import CosmosClient

from azure_auth import TenantCheckedCredential, guid
from generate_facility_incidents import read_dataset


ROOT = Path(__file__).resolve().parents[1]
CONTAINER_NAME = "FacilityIncidents"
SYSTEM_PROPERTIES = {"_rid", "_self", "_etag", "_attachments", "_ts"}


def validate_endpoint(endpoint: str) -> str:
    parsed = urlsplit(endpoint)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or not parsed.hostname.endswith(".cosmos.fabric.microsoft.com")
        or parsed.port not in (None, 443)
        or parsed.username
        or parsed.password
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("The endpoint is not a trusted Fabric Cosmos DB endpoint.")
    return endpoint


def synchronize(container: Any, expected: list[dict[str, Any]], verify_only: bool) -> None:
    properties = container.read()
    if properties["id"] != CONTAINER_NAME or properties["partitionKey"]["paths"] != ["/campusKey"]:
        raise ValueError("The Cosmos container does not match the reviewed partition-key contract.")
    throughput = container.get_throughput()
    if throughput.auto_scale_max_throughput != 1000:
        raise ValueError("The Cosmos container is not configured for the reviewed 1,000 RU/s autoscale maximum.")

    expected_by_key = {(item["id"], item["campusKey"]): item for item in expected}
    current = list(
        container.query_items(
            query="SELECT c.id, c.campusKey FROM c", enable_cross_partition_query=True
        )
    )
    current_keys = {(item["id"], item["campusKey"]) for item in current}
    if len(current_keys) != len(current) or not current_keys.issubset(expected_by_key):
        raise ValueError("The Cosmos container contains unexpected documents; nothing was changed.")

    for key in current_keys:
        observed = container.read_item(item=key[0], partition_key=key[1])
        content = {name: value for name, value in observed.items() if name not in SYSTEM_PROPERTIES}
        if content != expected_by_key[key]:
            raise ValueError(f"Existing incident {key[0]} differs from the seed; nothing was changed.")

    missing = expected_by_key.keys() - current_keys
    if verify_only and missing:
        raise ValueError(f"The Cosmos container is missing {len(missing)} expected incidents.")
    for key in sorted(missing):
        container.create_item(body=expected_by_key[key])

    for key, document in expected_by_key.items():
        observed = container.read_item(item=key[0], partition_key=key[1])
        content = {name: value for name, value in observed.items() if name not in SYSTEM_PROPERTIES}
        if content != document:
            raise ValueError(f"Incident {key[0]} does not match the seed after loading.")
    count = list(
        container.query_items(
            query="SELECT VALUE COUNT(1) FROM c", enable_cross_partition_query=True
        )
    )
    if count != [len(expected)]:
        raise ValueError("The final Cosmos incident count does not match the seed.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subscription-id", required=True, type=guid)
    parser.add_argument("--tenant-id", required=True, type=guid)
    parser.add_argument("--endpoint", required=True, type=validate_endpoint)
    parser.add_argument("--database-name", default="MacawFacilitiesIncidents")
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data" / "sources" / "cosmos")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    expected = read_dataset(args.data_dir)
    credential = TenantCheckedCredential(args.subscription_id, args.tenant_id)
    try:
        with CosmosClient(args.endpoint, credential=credential) as client:
            database = client.get_database_client(args.database_name)
            container = database.get_container_client(CONTAINER_NAME)
            synchronize(container, expected, args.verify_only)
    finally:
        credential.close()
    print(f"Verified {len(expected)} synthetic Cosmos incident documents.")
    print("No consumer access was granted; mirrored data and security require separate verification.")


if __name__ == "__main__":
    main()
