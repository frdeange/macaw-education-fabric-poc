import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class MedallionPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.definition = json.loads(
            (ROOT / "fabric" / "medallion-pipeline-content.json").read_text(
                encoding="utf-8"
            )
        )["properties"]
        cls.activities = {
            activity["name"]: activity for activity in cls.definition["activities"]
        }

    def test_silver_to_gold_waits_for_silver_success(self):
        dependency = self.activities["SilverToGold"]["dependsOn"]
        self.assertEqual(
            dependency,
            [
                {
                    "activity": "BronzeToSilver",
                    "dependencyConditions": ["Succeeded"],
                }
            ],
        )

    def test_enrichment_waits_for_validated_base_and_runs_in_order(self):
        for name, previous in (
            ("BronzeEnrichmentToSilver", "SilverToGold"),
            ("SilverEnrichmentToGold", "BronzeEnrichmentToSilver"),
        ):
            with self.subTest(activity=name):
                self.assertEqual(
                    self.activities[name]["dependsOn"],
                    [{"activity": previous, "dependencyConditions": ["Succeeded"]}],
                )

    def test_silver_receives_pipeline_snapshot_and_batch_parameters(self):
        silver = self.activities["BronzeToSilver"]["typeProperties"]["parameters"]
        parameters = self.definition["parameters"]
        self.assertEqual(
            parameters["expected_snapshot_date"]["defaultValue"], "2026-11-20"
        )
        self.assertEqual(
            parameters["batch_id"]["defaultValue"], "sql-mirror-2026-11-20-v1"
        )
        for name in ("expected_snapshot_date", "batch_id"):
            self.assertEqual(
                silver[name]["value"]["value"], f"@pipeline().parameters.{name}"
            )
            self.assertEqual(silver[name]["value"]["type"], "Expression")
        enrichment = self.activities["BronzeEnrichmentToSilver"]["typeProperties"]["parameters"]
        self.assertEqual(
            enrichment["expected_snapshot_date"]["value"],
            {"value": "@pipeline().parameters.expected_snapshot_date", "type": "Expression"},
        )

    def test_fail_activities_surface_each_notebook_failure(self):
        expected = {
            "FailAfterBronzeToSilver": "BronzeToSilver",
            "FailAfterSilverToGold": "SilverToGold",
            "FailAfterBronzeEnrichmentToSilver": "BronzeEnrichmentToSilver",
            "FailAfterSilverEnrichmentToGold": "SilverEnrichmentToGold",
        }
        for fail_name, upstream in expected.items():
            with self.subTest(activity=fail_name):
                fail = self.activities[fail_name]
                self.assertEqual(fail["type"], "Fail")
                self.assertEqual(
                    fail["dependsOn"],
                    [{"activity": upstream, "dependencyConditions": ["Failed"]}],
                )

    def test_notebook_activities_are_sequential_and_retryable(self):
        for name in (
            "BronzeToSilver", "SilverToGold",
            "BronzeEnrichmentToSilver", "SilverEnrichmentToGold",
        ):
            with self.subTest(activity=name):
                activity = self.activities[name]
                self.assertEqual(activity["type"], "TridentNotebook")
                self.assertEqual(activity["policy"]["retry"], 1)
                self.assertGreaterEqual(
                    activity["policy"]["retryIntervalInSeconds"], 30
                )


if __name__ == "__main__":
    unittest.main()
