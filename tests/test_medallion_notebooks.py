import ast
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from notebook_authoring import build_notebook


def assignment_value(path, assignment_name):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == assignment_name
            for target in node.targets
        ):
            return ast.literal_eval(node.value)
    raise AssertionError(f"Assignment not found: {assignment_name}")


class MedallionNotebookTests(unittest.TestCase):
    def test_source_key_and_count_contracts_match_reviewed_baselines(self):
        source_keys = assignment_value(ROOT / "notebooks" / "bronze_to_silver.py", "SOURCE_KEYS")
        expected_counts = assignment_value(
            ROOT / "notebooks" / "bronze_to_silver.py", "expected_counts"
        )
        table_contract = json.loads(
            (ROOT / "fabric" / "sql-bronze-tables.json").read_text(encoding="utf-8")
        )
        count_baseline = json.loads(
            (ROOT / "fabric" / "sql-bronze-baseline.json").read_text(encoding="utf-8")
        )

        self.assertEqual(
            source_keys,
            {table["name"]: table["keyColumns"] for table in table_contract["tables"]},
        )
        self.assertEqual(expected_counts, count_baseline["tableCounts"])

    def test_sql_source_loop_reads_reviewed_tables_from_schema_shortcut(self):
        source = ROOT / "notebooks" / "bronze_to_silver.py"
        source_keys = assignment_value(source, "SOURCE_KEYS")
        expected_counts = assignment_value(source, "expected_counts")
        tree = ast.parse(source.read_text(encoding="utf-8"))
        loop = next(
            node for node in tree.body
            if isinstance(node, ast.For)
            and isinstance(node.target, ast.Name)
            and node.target.id == "table_name"
        )
        reads = []
        integrity_checks = []

        class Reader:
            def format(self, value):
                self.format_name = value
                return self

            def load(self, path):
                reads.append((self.format_name, path))
                table = path.rsplit("/", 1)[-1]
                return SimpleNamespace(
                    columns=source_keys[table],
                    count=lambda: expected_counts[table],
                )

        def require(condition, message):
            if not condition:
                raise AssertionError(message)

        namespace = {
            "SOURCE_KEYS": source_keys,
            "expected_counts": expected_counts,
            "spark": SimpleNamespace(read=Reader()),
            "require": require,
            "assert_key_integrity": lambda frame, keys, table: integrity_checks.append(table),
            "source_tables": {},
            "actual_counts": {},
        }
        exec(compile(ast.Module(body=[loop], type_ignores=[]), str(source), "exec"), namespace)

        self.assertEqual(
            reads,
            [("delta", f"Tables/sql/{table}") for table in sorted(source_keys)],
        )
        self.assertEqual(integrity_checks, sorted(source_keys))
        self.assertEqual(namespace["actual_counts"], expected_counts)

    def test_enrichment_reads_schema_shortcuts_and_records_cosmos_lineage(self):
        source = ROOT / "notebooks" / "bronze_enrichment_to_silver.py"
        tree = ast.parse(source.read_text(encoding="utf-8"))
        assignments = [
            node for node in tree.body
            if isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id in {"assignments", "raw_incidents"}
                for target in node.targets
            )
        ]
        writes = [
            node for node in tree.body
            if isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Name)
            and node.value.func.id == "write_silver"
            and isinstance(node.value.args[0], ast.Constant)
            and node.value.args[0].value in {"facility_incident", "facility_incident_event"}
        ]
        spark = MagicMock()
        write_silver = MagicMock()
        namespace = {
            "spark": spark,
            "F": MagicMock(),
            "write_silver": write_silver,
            "incidents": MagicMock(),
            "incident_events": MagicMock(),
            "incident_batch_id": "test-batch",
        }
        exec(
            compile(ast.Module(body=assignments + writes, type_ignores=[]), str(source), "exec"),
            namespace,
        )

        loads = spark.read.format.return_value.load.call_args_list
        self.assertEqual(
            [call.args[0] for call in loads],
            ["Tables/sql/TeachingAssignment", "Tables/CosmosDB/FacilityIncidents"],
        )
        self.assertEqual(
            [call.args[3] for call in write_silver.call_args_list],
            [loads[1].args[0], loads[1].args[0]],
        )

    def test_attendance_output_contract_matches_observed_source_rows(self):
        source_counts = assignment_value(
            ROOT / "notebooks" / "bronze_to_silver.py", "expected_counts"
        )
        silver_counts = assignment_value(
            ROOT / "notebooks" / "bronze_to_silver.py", "expected_output_counts"
        )
        gold_totals = assignment_value(
            ROOT / "notebooks" / "silver_to_gold.py", "expected_totals"
        )

        observed_source_rows = source_counts["Attendance"]
        self.assertEqual(silver_counts["fact_attendance"], observed_source_rows)
        self.assertEqual(
            gold_totals["gold_attendance_by_campus_day"],
            ("observed_attendance_records", observed_source_rows),
        )

    def test_gold_student_department_bridge_deduplicates_subjects_not_departments(self):
        source = ROOT / "notebooks" / "silver_to_gold.py"
        tree = ast.parse(source.read_text(encoding="utf-8"))
        bridge = next(
            node for node in tree.body
            if isinstance(node, ast.Assign)
            and any(isinstance(target, ast.Name) and target.id == "gold_student_departments"
                    for target in node.targets)
        )

        class Rows:
            def __init__(self, rows):
                self.rows = rows

            def select(self, *columns):
                return Rows([tuple(row[column] for column in columns) for row in self.rows])

            def distinct(self):
                return set(self.rows)

        common = {"campus_key": 1, "academic_year_key": 1, "enrollment_key": 1, "student_key": 1}
        rows = [dict(common, department_key=1), dict(common, department_key=1),
                dict(common, department_key=2)]
        namespace = {"subject_enrollment": Rows(rows)}
        exec(compile(ast.Module(body=[bridge], type_ignores=[]), str(source), "exec"), namespace)
        self.assertEqual(namespace["gold_student_departments"], {(1, 1, 1, 1, 1), (1, 1, 1, 1, 2)})

    def test_built_notebooks_have_fabric_binding_and_valid_code_cells(self):
        parameters = {
            "bronze_lakehouse_name": "MacawEducationBronze",
            "silver_lakehouse_name": "MacawEducationSilver",
            "gold_lakehouse_name": "MacawEducationGold",
        }
        cases = [
            ("bronze_to_silver.py", "MacawEducationBronze"),
            ("silver_to_gold.py", "MacawEducationSilver"),
            ("bronze_enrichment_to_silver.py", "MacawEducationBronze"),
            ("silver_enrichment_to_gold.py", "MacawEducationSilver"),
        ]
        for filename, lakehouse_name in cases:
            with self.subTest(notebook=filename):
                notebook = build_notebook(
                    ROOT / "notebooks" / filename,
                    "11111111-1111-4111-8111-111111111111",
                    "22222222-2222-4222-8222-222222222222",
                    lakehouse_name,
                    parameters,
                )
                self.assertEqual(notebook["nbformat"], 4)
                self.assertEqual(
                    notebook["metadata"]["dependencies"]["lakehouse"][
                        "default_lakehouse_name"
                    ],
                    lakehouse_name,
                )
                code_cells = [cell for cell in notebook["cells"] if cell["cell_type"] == "code"]
                self.assertTrue(code_cells)
                self.assertEqual(code_cells[0]["metadata"]["tags"], ["parameters"])
                for cell in code_cells:
                    self.assertIsNone(cell["execution_count"])
                    self.assertEqual(cell["outputs"], [])
                    self.assertNotIn("__BRONZE_LAKEHOUSE_NAME__", "".join(cell["source"]))
                    self.assertNotIn("__SILVER_LAKEHOUSE_NAME__", "".join(cell["source"]))
                    self.assertNotIn("__GOLD_LAKEHOUSE_NAME__", "".join(cell["source"]))

    def test_curated_notebooks_exclude_person_names_and_preserve_measure_rules(self):
        silver = (ROOT / "notebooks" / "bronze_to_silver.py").read_text(encoding="utf-8")
        gold = (ROOT / "notebooks" / "silver_to_gold.py").read_text(encoding="utf-8")

        self.assertNotIn("FirstName", silver + gold)
        self.assertNotIn("LastName", silver + gold)
        self.assertIn('F.col("present_count") + F.col("late_count")', gold)
        self.assertIn('F.col("observed_attendance_records")', gold)
        self.assertIn('F.col("CalendarDate") <= snapshot_date', silver)
        self.assertIn('F.col("IsInstructionDay")', silver)
        self.assertIn('manifest["RunStatus"] == "Validated"', gold)

    def test_enrichment_preserves_plan_and_observation_boundaries(self):
        silver = (ROOT / "notebooks" / "bronze_enrichment_to_silver.py").read_text(encoding="utf-8")
        gold = (ROOT / "notebooks" / "silver_enrichment_to_gold.py").read_text(encoding="utf-8")
        self.assertIn('F.from_json("events", event_schema)', silver)
        self.assertIn('F.col("occurred_on") > F.lit(expected_snapshot_date)', silver)
        self.assertIn('"planned_weekly_assignment_count"', gold)
        self.assertNotIn("FirstName", silver + gold)
        self.assertNotIn("LastName", silver + gold)

    def test_gold_rejects_unvalidated_or_mismatched_postgres_batches(self):
        source_path = ROOT / "notebooks" / "silver_enrichment_to_gold.py"
        tree = ast.parse(source_path.read_text(encoding="utf-8"))
        check = next(
            node.value.args[0]
            for node in tree.body
            if isinstance(node, ast.Expr)
            and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Name)
            and node.value.func.id == "require"
            and len(node.value.args) == 2
            and isinstance(node.value.args[1], ast.Constant)
            and node.value.args[1].value
            == "Gold enrichment requires the current validated SQL and enrichment batches."
        )
        expression = compile(ast.Expression(check), str(source_path), "eval")
        sql_manifest = {
            "RunStatus": "Validated", "BatchId": "sql-batch",
            "SourceSnapshotDate": "2026-11-20",
        }
        source = {
            "RunStatus": "Validated", "SourceSqlBatchId": "sql-batch",
            "SourceSnapshotDate": "2026-11-20", "PostgreSQLStatus": "Validated",
        }
        self.assertTrue(eval(expression, {"sql_manifest": sql_manifest, "source": source}))
        for field, value in (
            ("PostgreSQLStatus", "Pending"), ("RunStatus", "Staging"),
            ("SourceSqlBatchId", "other"), ("SourceSnapshotDate", "2026-11-19"),
        ):
            with self.subTest(field=field):
                changed = dict(source, **{field: value})
                self.assertFalse(eval(expression, {"sql_manifest": sql_manifest, "source": changed}))


if __name__ == "__main__":
    unittest.main()
