"""Initialize or verify the synthetic facilities source on Azure PostgreSQL."""

from __future__ import annotations

import argparse
import ipaddress
import os
import re
import socket
import tempfile
from datetime import date
from pathlib import Path

import psycopg

from azure_auth import TenantCheckedCredential, guid
from generate_facility_incidents import read_dataset as read_incident_dataset
from generate_timetable import (
    CLOSURE_FIELDS,
    ROOM_FIELDS,
    build_assignments,
    build_closures,
    build_rooms,
    build_timetable,
    generate_dataset,
)


ROOT = Path(__file__).resolve().parents[1]
POSTGRES_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(network) for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)
MIRROR_PREREQUISITES_SQL = """
SELECT
    current_setting('wal_level'),
    current_setting('azure.fabric_mirror_enabled', true),
    EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'azure_cdc'),
    CASE
        WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'azure_cdc_admin')
        THEN pg_has_role(current_user, 'azure_cdc_admin', 'USAGE')
        ELSE false
    END,
    has_database_privilege(current_user, current_database(), 'CREATE'),
    to_regprocedure('azure_cdc.get_all_tables_mirror_status()') IS NOT NULL,
    CASE
        WHEN to_regprocedure('azure_cdc.get_all_tables_mirror_status()') IS NOT NULL
        THEN has_function_privilege(
            current_user, 'azure_cdc.get_all_tables_mirror_status()', 'EXECUTE'
        )
        ELSE false
    END,
    to_regprocedure('azure_cdc.check_prerequisites()') IS NOT NULL,
    CASE
        WHEN to_regprocedure('azure_cdc.check_prerequisites()') IS NOT NULL
        THEN has_function_privilege(
            current_user, 'azure_cdc.check_prerequisites()', 'EXECUTE'
        )
        ELSE false
    END
"""
MIRROR_CDC_PREREQUISITES_SQL = "SELECT status, data FROM azure_cdc.check_prerequisites()"
MIRROR_TABLE_STATUS_SQL = """
SELECT table_name, mirroring_status
FROM azure_cdc.get_all_tables_mirror_status()
WHERE table_schema = 'public'
  AND table_name IN ('facility_room', 'facility_closure')
"""


def azure_postgres_host(value: str) -> str:
    if not re.fullmatch(
        r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.postgres\.database\.azure\.com",
        value,
        flags=re.IGNORECASE,
    ):
        raise argparse.ArgumentTypeError("Use the Azure PostgreSQL server's canonical hostname.")
    return value.lower()


def postgres_database_name(value: str) -> str:
    if not re.fullmatch(r"[a-z_][a-z0-9_]{0,62}", value):
        raise argparse.ArgumentTypeError("Use a lowercase PostgreSQL database identifier.")
    return value


def resolve_address(host: str, *, allow_public: bool = False) -> str:
    addresses = {
        ipaddress.ip_address(result[4][0])
        for result in socket.getaddrinfo(host, 5432, family=socket.AF_INET, type=socket.SOCK_STREAM)
    }
    if allow_public:
        if not addresses or any(not address.is_global for address in addresses):
            raise RuntimeError("The PostgreSQL hostname must resolve exclusively to public IPv4 addresses.")
    elif not addresses or any(
        not any(address in network for network in PRIVATE_NETWORKS) for address in addresses
    ):
        raise RuntimeError("The PostgreSQL hostname must resolve exclusively to private IPv4 addresses.")
    return str(sorted(addresses)[0])


def expected_records() -> tuple[list[tuple[object, ...]], list[tuple[object, ...]]]:
    rooms = [tuple(row[field] for field in ROOM_FIELDS) for row in build_rooms()]
    timetable = build_timetable(build_assignments())
    closures = []
    for row in build_closures(timetable):
        closures.append(
            tuple(
                date.fromisoformat(str(row[field])) if field == "ClosureDate" else row[field]
                for field in CLOSURE_FIELDS
            )
        )
    return rooms, closures


def verify_local_sources() -> None:
    source_root = ROOT / "data" / "sources"
    with tempfile.TemporaryDirectory() as temporary_directory:
        generated_root = Path(temporary_directory) / "data" / "sources"
        manifest = generate_dataset(generated_root)
        paths = [Path(details["path"]) for details in manifest["files"].values()]
        paths.append(Path("timetable") / "manifest_2026_2027.json")
        for path in paths:
            if (generated_root / path).read_bytes() != (source_root / path).read_bytes():
                raise ValueError(f"The local source {path} differs from the deterministic snapshot.")
        if (
            (generated_root.parent.parent / "postgres" / "horizondb_seed.sql").read_bytes()
            != (ROOT / "postgres" / "horizondb_seed.sql").read_bytes()
        ):
            raise ValueError("The local PostgreSQL seed differs from the deterministic snapshot.")
    read_incident_dataset(source_root / "cosmos")


def load_or_verify(connection: psycopg.Connection, *, verify_only: bool) -> None:
    rooms, closures = expected_records()
    schema = (ROOT / "postgres" / "horizondb_schema.sql").read_text(encoding="utf-8")
    validation = (ROOT / "postgres" / "horizondb_validate.sql").read_text(encoding="utf-8")

    with connection.transaction():
        if verify_only:
            connection.execute("SET TRANSACTION READ ONLY")
            present = connection.execute(
                "SELECT to_regclass('public.facility_room') IS NOT NULL, "
                "to_regclass('public.facility_closure') IS NOT NULL"
            ).fetchone()
            if present != (True, True):
                raise ValueError("Both facilities tables must already exist for verification.")
        else:
            existing = connection.execute(
                "SELECT c.relname FROM pg_catalog.pg_class AS c "
                "JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace "
                "WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S')"
            ).fetchall()
            if existing:
                raise ValueError("The public schema contains existing relations; no facilities were loaded.")
            connection.execute(schema)
            with connection.cursor() as cursor:
                cursor.executemany(
                    "INSERT INTO public.facility_room "
                    "(room_key, campus_key, room_code, room_type, capacity) "
                    "VALUES (%s, %s, %s, %s, %s)",
                    rooms,
                )
                cursor.executemany(
                    "INSERT INTO public.facility_closure "
                    "(closure_key, campus_key, room_code, closure_date, closure_reason, status, source_version) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s)",
                    closures,
                )

        connection.execute(validation)
        actual_rooms = connection.execute(
            "SELECT room_key, campus_key, room_code, room_type, capacity "
            "FROM public.facility_room ORDER BY room_key"
        ).fetchall()
        actual_closures = connection.execute(
            "SELECT closure_key, campus_key, room_code, closure_date, closure_reason, status, source_version "
            "FROM public.facility_closure ORDER BY closure_key"
        ).fetchall()
        if actual_rooms != rooms or actual_closures != closures:
            raise ValueError("The PostgreSQL facilities do not match the generated synthetic snapshot.")


def check_mirroring_readiness(connection: psycopg.Connection) -> None:
    with connection.transaction():
        connection.execute("SET TRANSACTION READ ONLY")
        prerequisites = connection.execute(MIRROR_PREREQUISITES_SQL).fetchone()
        if prerequisites is None:
            raise RuntimeError("PostgreSQL returned no mirroring prerequisite information.")
        (
            wal_level,
            enabled,
            cdc_installed,
            cdc_admin,
            database_create,
            status_exists,
            status_execute,
            check_exists,
            check_execute,
        ) = prerequisites
        failures = []
        if wal_level != "logical":
            failures.append("wal_level is not logical")
        if enabled != "on":
            failures.append("azure.fabric_mirror_enabled is not on or cannot be read")
        if not cdc_installed:
            failures.append("azure_cdc is not registered in the current database")
        if not cdc_admin:
            failures.append("the connected role cannot use azure_cdc_admin")
        if not database_create:
            failures.append("the connected role lacks CREATE on the database")
        if not status_exists:
            failures.append("the azure_cdc table eligibility function is unavailable")
        elif not status_execute:
            failures.append("the connected role cannot EXECUTE the azure_cdc table eligibility function")
        if not check_exists:
            failures.append("the azure_cdc prerequisite function is unavailable")
        elif not check_execute:
            failures.append("the connected role cannot EXECUTE the azure_cdc prerequisite function")
        if failures:
            raise RuntimeError("PostgreSQL mirroring checks failed: " + "; ".join(failures) + ".")

        cdc_results = connection.execute(MIRROR_CDC_PREREQUISITES_SQL).fetchall()
        if len(cdc_results) != 1:
            raise RuntimeError("Expected exactly one CDC prerequisite result.")
        cdc_status, details = cdc_results[0]
        if not isinstance(details, list) or any(not isinstance(item, dict) for item in details):
            raise RuntimeError("PostgreSQL returned invalid CDC prerequisite details.")
        failed_codes = []
        for item in details:
            if item.get("status") != "OK":
                code = item.get("status_code")
                failed_codes.append(
                    code if isinstance(code, str) and re.fullmatch(r"[A-Z0-9_]+", code) else "UNKNOWN"
                )
        if cdc_status != "OK" or failed_codes:
            codes = f": {', '.join(failed_codes)}" if failed_codes else ""
            raise RuntimeError(f"CDC prerequisites returned {cdc_status!r}{codes}.")

        statuses = connection.execute(MIRROR_TABLE_STATUS_SQL).fetchall()
        for table in ("facility_room", "facility_closure"):
            matches = [status for name, status in statuses if name == table]
            if len(matches) != 1:
                raise RuntimeError(f"Expected exactly one CDC eligibility result for {table}.")
            if matches[0] != "OK":
                raise RuntimeError(f"CDC eligibility for {table} is {matches[0]!r}, not 'OK'.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subscription-id", required=True, type=guid)
    parser.add_argument("--tenant-id", required=True, type=guid)
    parser.add_argument("--server", required=True, type=azure_postgres_host)
    parser.add_argument("--database-name", required=True, type=postgres_database_name)
    parser.add_argument("--ca-bundle", required=True, type=Path)
    parser.add_argument("--allow-public", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--check-mirroring-readiness", action="store_true")
    args = parser.parse_args()

    if args.check_mirroring_readiness and not args.verify_only:
        parser.error("--check-mirroring-readiness requires --verify-only.")
    user = os.environ.get("PGUSER", "").strip()
    if not user:
        parser.error("Set PGUSER temporarily to the PostgreSQL Entra administrator's user name.")
    if not args.ca_bundle.is_file():
        parser.error("The PostgreSQL trusted root CA bundle must be an existing PEM file.")

    verify_local_sources()
    address = resolve_address(args.server, allow_public=args.allow_public)
    credential = TenantCheckedCredential(args.subscription_id, args.tenant_id)
    try:
        token = credential.get_token(POSTGRES_SCOPE).token
        with psycopg.connect(
            host=args.server,
            hostaddr=address,
            port=5432,
            dbname=args.database_name,
            user=user,
            password=token,
            gssencmode="disable",
            sslmode="verify-full",
            sslrootcert=str(args.ca_bundle.resolve()),
            connect_timeout=15,
            application_name="macaw-facilities-seed",
        ) as connection:
            load_or_verify(connection, verify_only=args.verify_only)
            if args.check_mirroring_readiness:
                check_mirroring_readiness(connection)
    finally:
        credential.close()
    print("Verified 300 synthetic rooms and 10 planned closures in PostgreSQL.")
    if args.check_mirroring_readiness:
        print("Checked source-side CDC, database permissions and table eligibility for the connected role.")
    print("Mirroring and consumer security require separate configuration and verification.")


if __name__ == "__main__":
    main()
