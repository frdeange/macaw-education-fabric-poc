import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import foundry_eval


class FoundryEvaluationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.args = SimpleNamespace(account="account", project="project", version="1", model="model")

    @patch("foundry_eval.AIProjectClient")
    def test_submits_pinned_agent_generation_without_running_an_evaluation(self, client) -> None:
        project = client.return_value.__enter__.return_value
        project.datasets.list.return_value = []
        project.datasets.list_generation_jobs.return_value = []
        project.evaluators.list.return_value = []
        project.evaluators.list_generation_jobs.return_value = []
        project.datasets.begin_create_generation_job.return_value.details = {"job_id": "data-id"}
        project.evaluators.begin_create_generation_job.return_value.details = {"job_id": "evaluator-id"}

        with contextlib.redirect_stdout(io.StringIO()) as output:
            foundry_eval.start(self.args, credential=None)

        data_args = project.datasets.begin_create_generation_job.call_args
        evaluator_args = project.evaluators.begin_create_generation_job.call_args
        self.assertEqual(data_args.args[0].sources[0].agent_version, "1")
        self.assertEqual(evaluator_args.args[0].sources[0].agent_version, "1")
        self.assertEqual(data_args.args[0].generation_configuration.max_samples, 15)
        self.assertFalse(data_args.kwargs["polling"])
        self.assertFalse(evaluator_args.kwargs["polling"])
        self.assertIn("data-id", output.getvalue())
        self.assertIn("evaluator-id", output.getvalue())
        project.get_openai_client.assert_not_called()

    @patch("foundry_eval.AIProjectClient")
    def test_existing_job_prevents_duplicate_generation(self, client) -> None:
        project = client.return_value.__enter__.return_value
        project.datasets.list.return_value = []
        project.evaluators.list.return_value = []
        project.datasets.list_generation_jobs.return_value = [SimpleNamespace(name=foundry_eval.DATASET_NAME)]

        with self.assertRaisesRegex(RuntimeError, "generation job already exists"):
            foundry_eval.start(self.args, credential=None)

        project.datasets.begin_create_generation_job.assert_not_called()
        project.evaluators.begin_create_generation_job.assert_not_called()

    @patch("foundry_eval.AIProjectClient")
    def test_can_inspect_a_single_job_after_a_partial_submission(self, client) -> None:
        project = client.return_value.__enter__.return_value
        project.datasets.get_generation_job.return_value = SimpleNamespace(
            id="data-id", status="failed", result=None, error=None
        )
        self.args.data_job_id = "data-id"
        self.args.evaluator_job_id = None

        with contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaisesRegex(RuntimeError, "data: failed"):
                foundry_eval.status(self.args, credential=None)

        self.assertIn('"status": "failed"', output.getvalue())
        project.evaluators.get_generation_job.assert_not_called()

    def configure_export(self, client, output_dir: Path):
        project = client.return_value.__enter__.return_value
        self.args.data_job_id = "data-id"
        self.args.evaluator_job_id = "evaluator-id"
        self.args.output_dir = output_dir
        project.datasets.get_generation_job.return_value = SimpleNamespace(
            status="succeeded",
            result=SimpleNamespace(
                outputs=[SimpleNamespace(type="dataset", name=foundry_eval.DATASET_NAME, version="1.0")],
                generated_samples=2,
            ),
        )
        project.evaluators.get_generation_job.return_value = SimpleNamespace(
            status="succeeded",
            result=SimpleNamespace(name=foundry_eval.EVALUATOR_NAME, version="1", id="evaluator-asset"),
        )
        project.datasets.get.return_value = SimpleNamespace(
            name=foundry_eval.DATASET_NAME,
            version="1.0",
            type="uri_file",
            tags={"data_generation_job_id": "data-id"},
            data_uri="https://account.blob.core.windows.net/container",
        )
        project.datasets.get_credentials.return_value = SimpleNamespace(
            blob_reference=SimpleNamespace(
                blob_uri="https://account.blob.core.windows.net/container",
                credential=SimpleNamespace(sas_uri="https://account.blob.core.windows.net/container?sr=c&sig=secret"),
            )
        )
        registered = Mock()
        registered.id = "evaluator-asset"
        registered.definition = {"dimensions": []}
        registered.as_dict.return_value = {"id": "evaluator-asset", "definition": {"dimensions": []}}
        project.evaluators.get_version.return_value = registered
        return project

    @patch("foundry_eval.urlopen")
    @patch("foundry_eval.AIProjectClient")
    def test_exports_generated_artifacts_without_saving_or_printing_credentials(self, client, urlopen) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            project = self.configure_export(client, output_dir)
            dataset_dir = output_dir / "datasets"
            questions_file = dataset_dir / "macaw-education-assistant-macaw-education-smoke-v1.0-questions.jsonl"
            dataset_file = dataset_dir / "macaw-education-assistant-macaw-education-smoke-v1.0.jsonl"
            evaluator_file = output_dir / "evaluators" / "macaw-education-quality-v1.json"
            urlopen.return_value.__enter__.return_value.read.return_value = (
                b'{"id":1,"query":"one","candidate_response":"unverified"}\n'
                b'{"id":2,"query":"two","candidate_response":"unverified"}\n'
            )
            with contextlib.redirect_stdout(io.StringIO()) as output:
                foundry_eval.export_artifacts(self.args, credential=None)
                foundry_eval.export_artifacts(self.args, credential=None)
            self.assertEqual(
                questions_file.read_text(),
                '{"id": 1, "query": "one"}\n{"id": 2, "query": "two"}\n',
            )
            self.assertNotIn("secret", output.getvalue())
            self.assertNotIn("secret", evaluator_file.read_text())
            project.evaluators.get_version.assert_called_with(foundry_eval.EVALUATOR_NAME, "1")
            project.get_openai_client.assert_not_called()
            dataset_file.write_text("local edits")
            with self.assertRaisesRegex(RuntimeError, "Refusing to overwrite"):
                foundry_eval.export_artifacts(self.args, credential=None)
            self.assertEqual(dataset_file.read_text(), "local edits")

    @patch("foundry_eval.urlopen")
    @patch("foundry_eval.AIProjectClient")
    def test_rejects_mismatched_storage_credentials(self, client, urlopen) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = self.configure_export(client, Path(directory))
            project.datasets.get_credentials.return_value.blob_reference.blob_uri = (
                "https://other.blob.core.windows.net/container"
            )
            with self.assertRaisesRegex(RuntimeError, "locations do not match"):
                foundry_eval.export_artifacts(self.args, credential=None)
            urlopen.assert_not_called()

    @patch("foundry_eval.urlopen")
    @patch("foundry_eval.AIProjectClient")
    def test_rejects_incomplete_dataset_before_writing(self, client, urlopen) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            self.configure_export(client, output_dir)
            urlopen.return_value.__enter__.return_value.read.return_value = b'{"query":"one"}\n'
            with self.assertRaisesRegex(RuntimeError, "sample count"):
                foundry_eval.export_artifacts(self.args, credential=None)
            self.assertFalse(any(output_dir.iterdir()))

    @patch("foundry_eval.urlopen")
    @patch("foundry_eval.AIProjectClient")
    def test_rejects_signed_urls_in_generated_data(self, client, urlopen) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            self.configure_export(client, output_dir)
            urlopen.return_value.__enter__.return_value.read.return_value = (
                b'{"id":1,"query":"https://example.test/?sig=secret"}\n{"id":2,"query":"two"}\n'
            )
            with self.assertRaisesRegex(RuntimeError, "contains a signed URL"):
                foundry_eval.export_artifacts(self.args, credential=None)
            self.assertFalse(any(output_dir.iterdir()))

    @patch("foundry_eval.urlopen")
    @patch("foundry_eval.AIProjectClient")
    def test_rejects_duplicate_question_ids(self, client, urlopen) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            self.configure_export(client, output_dir)
            urlopen.return_value.__enter__.return_value.read.return_value = (
                b'{"id":1,"query":"one"}\n{"id":1,"query":"two"}\n'
            )
            with self.assertRaisesRegex(RuntimeError, "unique numeric IDs"):
                foundry_eval.export_artifacts(self.args, credential=None)
            self.assertFalse(any(output_dir.iterdir()))


if __name__ == "__main__":
    unittest.main()
