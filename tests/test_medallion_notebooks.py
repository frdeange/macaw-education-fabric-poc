import ast
import json
import sys
import unittest
from pathlib import Path


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

    def test_built_notebooks_have_fabric_binding_and_valid_code_cells(self):
        parameters = {
            "bronze_lakehouse_name": "MacawEducationBronze",
            "silver_lakehouse_name": "MacawEducationSilver",
            "gold_lakehouse_name": "MacawEducationGold",
        }
        cases = [
            ("bronze_to_silver.py", "MacawEducationBronze"),
            ("silver_to_gold.py", "MacawEducationSilver"),
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


if __name__ == "__main__":
    unittest.main()
