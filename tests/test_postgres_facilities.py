import argparse
import copy
import os
import socket
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))
from scripts.load_postgres_facilities import (
    azure_postgres_host,
    check_mirroring_readiness,
    expected_records,
    load_or_verify,
    main,
    postgres_database_name,
    resolve_address,
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
        self.assertEqual(resolve_address("example.postgres.database.azure.com"), "10.2.0.4")
        for addresses in ([], [result("52.1.2.3")], [result("10.2.0.4"), result("52.1.2.3")]):
            resolve.return_value = addresses
            with self.subTest(addresses=addresses), self.assertRaisesRegex(RuntimeError, "exclusively"):
                resolve_address("example.postgres.database.azure.com")

    @patch("scripts.load_postgres_facilities.socket.getaddrinfo")
    def test_public_dns_requires_opt_in_and_rejects_mixed_addresses(self, resolve):
        def result(address):
            return (socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 5432))

        resolve.return_value = [result("52.1.2.3")]
        self.assertEqual(resolve_address("example.postgres.database.azure.com", allow_public=True), "52.1.2.3")
        for addresses in ([], [result("10.2.0.4")], [result("10.2.0.4"), result("52.1.2.3")]):
            resolve.return_value = addresses
            with self.subTest(addresses=addresses), self.assertRaisesRegex(RuntimeError, "exclusively"):
                resolve_address("example.postgres.database.azure.com", allow_public=True)

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

    def test_mirroring_readiness_checks_both_tables_in_a_read_only_transaction(self):
        connection = MagicMock()
        connection.execute.return_value.fetchone.return_value = (
            "logical", "on", True, True, True, True, True, True, True
        )
        connection.execute.return_value.fetchall.side_effect = [
            [("OK", [])],
            [("facility_room", "OK"), ("facility_closure", "OK")],
        ]
        check_mirroring_readiness(connection)
        self.assertEqual(connection.execute.call_args_list[0].args[0], "SET TRANSACTION READ ONLY")
        self.assertIn("to_regprocedure('azure_cdc.check_prerequisites()')", connection.execute.call_args_list[1].args[0])
        self.assertIn("azure_cdc.check_prerequisites()", connection.execute.call_args_list[2].args[0])
        self.assertIn("azure_cdc.get_all_tables_mirror_status()", connection.execute.call_args_list[3].args[0])
        self.assertEqual(connection.execute.call_count, 4)

    def test_mirroring_readiness_rejects_missing_prerequisites(self):
        valid = ("logical", "on", True, True, True, True, True, True, True)
        cases = (
            (0, "replica", "wal_level"),
            (1, None, "azure.fabric_mirror_enabled"),
            (2, False, "azure_cdc is not registered"),
            (3, False, "azure_cdc_admin"),
            (4, False, "lacks CREATE"),
            (5, False, "eligibility function is unavailable"),
            (6, False, "cannot EXECUTE"),
            (7, False, "prerequisite function is unavailable"),
            (8, False, "cannot EXECUTE the azure_cdc prerequisite function"),
        )
        for index, value, message in cases:
            with self.subTest(message=message):
                connection = MagicMock()
                values = list(valid)
                values[index] = value
                connection.execute.return_value.fetchone.return_value = tuple(values)
                with self.assertRaisesRegex(RuntimeError, message):
                    check_mirroring_readiness(connection)
                self.assertEqual(connection.execute.call_count, 2)

    def test_mirroring_readiness_rejects_failed_or_ambiguous_cdc_prerequisites(self):
        cases = (
            (
                [("ERROR", [{"status": "ERROR", "status_code": "MAX_WORKER_PROCESSES_TOO_LOW"}])],
                "MAX_WORKER_PROCESSES_TOO_LOW",
            ),
            ([("OK", [{"status": "ERROR", "status_code": "SERVER_IN_RECOVERY"}])], "SERVER_IN_RECOVERY"),
            ([], "exactly one CDC prerequisite result"),
            ([("OK", []), ("OK", [])], "exactly one CDC prerequisite result"),
            ([("OK", None)], "invalid CDC prerequisite details"),
            ([("UNKNOWN", [])], "UNKNOWN"),
        )
        for result, message in cases:
            with self.subTest(result=result):
                connection = MagicMock()
                connection.execute.return_value.fetchone.return_value = (
                    "logical", "on", True, True, True, True, True, True, True
                )
                connection.execute.return_value.fetchall.return_value = result
                with self.assertRaisesRegex(RuntimeError, message):
                    check_mirroring_readiness(connection)
                self.assertEqual(connection.execute.call_count, 3)

    def test_mirroring_readiness_rejects_missing_duplicate_or_unhealthy_table_status(self):
        cases = (
            ([("facility_room", "OK")], "exactly one CDC eligibility result"),
            (
                [("facility_room", "OK"), ("facility_room", "OK"), ("facility_closure", "OK")],
                "exactly one CDC eligibility result",
            ),
            ([("facility_room", "WARNING"), ("facility_closure", "OK")], "WARNING"),
            ([("facility_room", "OK"), ("facility_closure", "ERROR")], "ERROR"),
        )
        for statuses, message in cases:
            with self.subTest(statuses=statuses):
                connection = MagicMock()
                connection.execute.return_value.fetchone.return_value = (
                    "logical", "on", True, True, True, True, True, True, True
                )
                connection.execute.return_value.fetchall.side_effect = [[("OK", [])], statuses]
                with self.assertRaisesRegex(RuntimeError, message):
                    check_mirroring_readiness(connection)

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
                patch(f"{module}.resolve_address", return_value="10.2.0.4") as resolve,
                patch(f"{module}.TenantCheckedCredential") as credential_type,
                patch(f"{module}.psycopg.connect") as connect,
                patch(f"{module}.load_or_verify") as load,
                patch(f"{module}.check_mirroring_readiness") as check_readiness,
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
                check_readiness.assert_not_called()
                credential.close.assert_called_once_with()
                arguments.append("--check-mirroring-readiness")
                main()
                check_readiness.assert_called_once_with(connect.return_value.__enter__.return_value)
                resolve.reset_mock()
                credential_type.reset_mock()
                verify_sources.side_effect = ValueError("Local sources do not match.")
                with self.assertRaisesRegex(ValueError, "Local sources do not match"):
                    main()
                resolve.assert_not_called()
                credential_type.assert_not_called()

    def test_mirroring_check_requires_read_only_verification(self):
        arguments = [
            "loader",
            "--subscription-id", "11111111-1111-1111-1111-111111111111",
            "--tenant-id", "22222222-2222-2222-2222-222222222222",
            "--server", "example.postgres.database.azure.com",
            "--database-name", "macaw_facilities",
            "--ca-bundle", "roots.pem",
            "--check-mirroring-readiness",
        ]
        error_output = StringIO()
        with (
            patch.object(sys, "argv", arguments),
            patch("scripts.load_postgres_facilities.verify_local_sources") as verify_sources,
            redirect_stderr(error_output),
            self.assertRaises(SystemExit) as error,
        ):
            main()
        self.assertEqual(error.exception.code, 2)
        self.assertIn("requires --verify-only", error_output.getvalue())
        verify_sources.assert_not_called()


if __name__ == "__main__":
    unittest.main()
