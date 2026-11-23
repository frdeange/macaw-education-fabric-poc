import argparse
import copy
import os
import socket
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
from scripts.load_postgres_facilities import (
    azure_postgres_host,
    expected_records,
    load_or_verify,
    main,
    postgres_database_name,
    private_address,
    verify_local_sources,
)
from scripts.generate_facility_incidents import write_dataset as write_incident_dataset
from scripts.generate_timetable import generate_dataset


class PostgresFacilitiesTests(unittest.TestCase):
    def test_only_canonical_postgres_hostnames_are_accepted(self):
        self.assertEqual(
            azure_postgres_host("EXAMPLE.postgres.database.azure.com"),
            "example.postgres.database.azure.com",
        )
        for host in (
            "example.postgres.database.azure.com.evil.example",
            "example.postgres.database.azure.com:5432",
            "127.0.0.1",
            "https://example.postgres.database.azure.com",
        ):
            with self.subTest(host=host), self.assertRaises(argparse.ArgumentTypeError):
                azure_postgres_host(host)

    def test_database_name_cannot_override_connection_options(self):
        self.assertEqual(postgres_database_name("macaw_facilities"), "macaw_facilities")
        for name in ("host=other", "postgresql://other/database", "name with spaces"):
            with self.subTest(name=name), self.assertRaises(argparse.ArgumentTypeError):
                postgres_database_name(name)

    @patch("scripts.load_postgres_facilities.socket.getaddrinfo")
    def test_public_or_mixed_dns_results_are_rejected(self, resolve):
        def result(address):
            return (socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 5432))

        resolve.return_value = [result("10.2.0.4")]
        self.assertEqual(private_address("example.postgres.database.azure.com"), "10.2.0.4")
        for addresses in ([], [result("52.1.2.3")], [result("10.2.0.4"), result("52.1.2.3")]):
            resolve.return_value = addresses
            with self.subTest(addresses=addresses), self.assertRaisesRegex(RuntimeError, "exclusively"):
                private_address("example.postgres.database.azure.com")

    def test_initialization_refuses_an_existing_public_object(self):
        connection = MagicMock()
        connection.execute.return_value.fetchall.return_value = [("unrelated_table",)]
        with self.assertRaisesRegex(ValueError, "existing relations"):
            load_or_verify(connection, verify_only=False)
        connection.cursor.assert_not_called()
        transaction = connection.transaction.return_value
        self.assertIs(transaction.__exit__.call_args.args[0], ValueError)

    def test_verification_rejects_missing_tables_without_writes(self):
        connection = MagicMock()
        connection.execute.return_value.fetchone.return_value = (True, False)
        with self.assertRaisesRegex(ValueError, "must already exist"):
            load_or_verify(connection, verify_only=True)
        connection.cursor.assert_not_called()
        self.assertEqual(connection.execute.call_args_list[0].args[0], "SET TRANSACTION READ ONLY")

    def test_changed_existing_data_is_rejected(self):
        rooms, closures = expected_records()
        changed_closures = copy.copy(closures)
        changed_closures[0] = (*changed_closures[0][:-1], "unexpected-version")
        connection = MagicMock()
        connection.execute.return_value.fetchone.return_value = (True, True)
        connection.execute.return_value.fetchall.side_effect = [rooms, changed_closures]
        with self.assertRaisesRegex(ValueError, "do not match"):
            load_or_verify(connection, verify_only=True)
        transaction = connection.transaction.return_value
        self.assertIs(transaction.__exit__.call_args.args[0], ValueError)

    def test_inconsistent_local_sources_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_root = root / "data" / "sources"
            generate_dataset(source_root)
            write_incident_dataset(source_root / "cosmos")
            with patch("scripts.load_postgres_facilities.ROOT", root):
                verify_local_sources()
                timetable = source_root / "timetable" / "timetable_2026_2027.csv"
                original = timetable.read_bytes()
                timetable.write_bytes(original + b"changed")
                with self.assertRaisesRegex(ValueError, "differs from the deterministic snapshot"):
                    verify_local_sources()
                timetable.write_bytes(original)
                incidents = source_root / "cosmos" / "facility_incidents_2026_2027.jsonl"
                incidents.write_bytes(incidents.read_bytes() + b"changed")
                with self.assertRaisesRegex(ValueError, "manifest"):
                    verify_local_sources()

    def test_connection_uses_tenant_checked_token_and_verified_tls(self):
        module = "scripts.load_postgres_facilities"
        subscription = "11111111-1111-1111-1111-111111111111"
        tenant = "22222222-2222-2222-2222-222222222222"
        with tempfile.TemporaryDirectory() as temporary_directory:
            bundle = Path(temporary_directory) / "roots.pem"
            bundle.write_text("test-only", encoding="utf-8")
            arguments = [
                "loader",
                "--subscription-id", subscription,
                "--tenant-id", tenant,
                "--server", "example.postgres.database.azure.com",
                "--database-name", "macaw_facilities",
                "--ca-bundle", str(bundle),
                "--verify-only",
            ]
            with (
                patch.object(sys, "argv", arguments),
                patch.dict(os.environ, {"PGUSER": "example-user"}),
                patch(f"{module}.verify_local_sources") as verify_sources,
                patch(f"{module}.private_address", return_value="10.2.0.4") as resolve,
                patch(f"{module}.TenantCheckedCredential") as credential_type,
                patch(f"{module}.psycopg.connect") as connect,
                patch(f"{module}.load_or_verify") as load,
                redirect_stdout(StringIO()),
            ):
                credential = credential_type.return_value
                credential.get_token.return_value.token = "test-token"
                main()
                verify_sources.assert_called_once_with()
                credential_type.assert_called_once_with(subscription, tenant)
                credential.get_token.assert_called_once_with(
                    "https://ossrdbms-aad.database.windows.net/.default"
                )
                self.assertEqual(connect.call_args.kwargs["hostaddr"], "10.2.0.4")
                self.assertEqual(connect.call_args.kwargs["host"], "example.postgres.database.azure.com")
                self.assertEqual(connect.call_args.kwargs["port"], 5432)
                self.assertEqual(connect.call_args.kwargs["password"], "test-token")
                self.assertEqual(connect.call_args.kwargs["gssencmode"], "disable")
                self.assertEqual(connect.call_args.kwargs["sslmode"], "verify-full")
                self.assertEqual(connect.call_args.kwargs["sslrootcert"], str(bundle.resolve()))
                load.assert_called_once_with(connect.return_value.__enter__.return_value, verify_only=True)
                credential.close.assert_called_once_with()
                resolve.reset_mock()
                credential_type.reset_mock()
                verify_sources.side_effect = ValueError("Local sources do not match.")
                with self.assertRaisesRegex(ValueError, "Local sources do not match"):
                    main()
                resolve.assert_not_called()
                credential_type.assert_not_called()


if __name__ == "__main__":
    unittest.main()
