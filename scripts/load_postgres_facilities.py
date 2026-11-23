"""Initialize or verify the synthetic facilities source on private Azure PostgreSQL."""

from __future__ import annotations

import argparse
import ipaddress
import os
import re
import socket
from datetime import date
from pathlib import Path

import psycopg

from azure_auth import TenantCheckedCredential, guid
from generate_timetable import (
    CLOSURE_FIELDS,
    ROOM_FIELDS,
    build_assignments,
    build_closures,
    build_rooms,
    build_timetable,
)


ROOT = Path(__file__).resolve().parents[1]
POSTGRES_SCOPE = "https://ossrdbms-aad.database.windows.net/.default"
PRIVATE_NETWORKS = tuple(
    ipaddress.ip_network(network) for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
)


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


def private_address(host: str) -> str:
    addresses = {
        ipaddress.ip_address(result[4][0])
        for result in socket.getaddrinfo(host, 5432, family=socket.AF_INET, type=socket.SOCK_STREAM)
    }
    if not addresses or any(
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subscription-id", required=True, type=guid)
    parser.add_argument("--tenant-id", required=True, type=guid)
    parser.add_argument("--server", required=True, type=azure_postgres_host)
    parser.add_argument("--database-name", required=True, type=postgres_database_name)
    parser.add_argument("--ca-bundle", required=True, type=Path)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    user = os.environ.get("PGUSER", "").strip()
    if not user:
        parser.error("Set PGUSER temporarily to the PostgreSQL Entra administrator's user name.")
    if not args.ca_bundle.is_file():
        parser.error("The PostgreSQL trusted root CA bundle must be an existing PEM file.")

    address = private_address(args.server)
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
    finally:
        credential.close()
    print("Verified 300 synthetic rooms and 10 planned closures in PostgreSQL.")
    print("Mirroring and consumer security require separate configuration and verification.")


if __name__ == "__main__":
    main()
