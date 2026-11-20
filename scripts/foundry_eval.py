import argparse
import json
import re
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlsplit, urlunsplit
from urllib.request import urlopen
from uuid import NAMESPACE_URL, uuid5

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    AgentDataGenerationJobSource,
    AgentEvaluatorGenerationJobSource,
    DataGenerationModelOptions,
    EvaluationDataGenerationJobInputs,
    EvaluationDataGenerationJobOutputConfiguration,
    EvaluatorGenerationInputs,
    PromptDataGenerationJobSource,
    PromptEvaluatorGenerationJobSource,
    SimpleQnADataGenerationJobConfiguration,
)

from foundry_agent import TenantCheckedCredential, agent_config, guid, project_endpoint


DATASET_NAME = "macaw-education-smoke"
EVALUATOR_NAME = "macaw-education-quality"
SCENARIO = (
    "Generate English test questions about synthetic Dutch school enrollment, class size, "
    "attendance and assessment results. Include questions about enrollment by individual "
    "subject and about subject-specific attendance, which the model cannot answer. "
    "Do not assume unverified security permissions or invent educational data."
)
RUBRIC = (
    "Assess whether the answer is grounded in the Fabric tools, uses the relevant tool, "
    "acknowledges missing data or access, and does not invent facts. Enrollment by "
    "individual subject is supported; attendance by individual subject should be declined "
    "because the model does not support it. Respect the synthetic snapshot and qualitative primary outcomes."
)


def start(args: argparse.Namespace, credential: TenantCheckedCredential) -> None:
    config = agent_config()
    endpoint = project_endpoint(args.account, args.project)
    with AIProjectClient(endpoint=endpoint, credential=credential) as project:
        project.agents.get_version(agent_name=config["name"], agent_version=args.version)
        if any(d.name == DATASET_NAME for d in project.datasets.list()):
            raise RuntimeError(f"Dataset {DATASET_NAME} already exists; inspect it before generating.")
        if any(e.name == EVALUATOR_NAME for e in project.evaluators.list(type="custom")):
            raise RuntimeError(f"Evaluator {EVALUATOR_NAME} already exists; inspect it before generating.")
        if any(j.name == DATASET_NAME for j in project.datasets.list_generation_jobs()):
            raise RuntimeError(f"A {DATASET_NAME} generation job already exists; inspect it before retrying.")
        if any(j.evaluator_name == EVALUATOR_NAME for j in project.evaluators.list_generation_jobs()):
            raise RuntimeError(f"An {EVALUATOR_NAME} generation job already exists; inspect it before retrying.")

        dataset_job = EvaluationDataGenerationJobInputs(
            name=DATASET_NAME,
            sources=[
                AgentDataGenerationJobSource(agent_name=config["name"], agent_version=args.version),
                PromptDataGenerationJobSource(prompt=SCENARIO),
            ],
            generation_configuration=SimpleQnADataGenerationJobConfiguration(
                max_samples=15, model_options=DataGenerationModelOptions(model=args.model)
            ),
            output_configuration=EvaluationDataGenerationJobOutputConfiguration(name=DATASET_NAME),
        )
        data_poller = project.datasets.begin_create_generation_job(
            dataset_job,
            operation_id=str(uuid5(NAMESPACE_URL, f"{endpoint}/{config['name']}/{args.version}/data")),
            polling=False,
        )
        data_id = data_poller.details.get("job_id")
        if not data_id:
            raise RuntimeError("The data generation request returned no job ID; inspect the project before retrying.")
        print(f"Data generation job ID: {data_id}", flush=True)

        evaluator_job = EvaluatorGenerationInputs(
            evaluator_name=EVALUATOR_NAME,
            evaluator_display_name="Macaw education quality",
            evaluator_description="Quality and groundedness for the Macaw education assistant.",
            category="quality",
            model=args.model,
            sources=[
                AgentEvaluatorGenerationJobSource(agent_name=config["name"], agent_version=args.version),
                PromptEvaluatorGenerationJobSource(prompt=RUBRIC),
            ],
        )
        evaluator_poller = project.evaluators.begin_create_generation_job(
            evaluator_job,
            operation_id=str(uuid5(NAMESPACE_URL, f"{endpoint}/{config['name']}/{args.version}/evaluator")),
            polling=False,
        )
        evaluator_id = evaluator_poller.details.get("job_id")
        if not evaluator_id:
            raise RuntimeError("The evaluator request returned no job ID; inspect the project before retrying.")
        print(f"Evaluator generation job ID: {evaluator_id}", flush=True)


def status(args: argparse.Namespace, credential: TenantCheckedCredential) -> None:
    if not args.data_job_id and not args.evaluator_job_id:
        raise ValueError("Provide at least one generation job ID.")
    endpoint = project_endpoint(args.account, args.project)
    with AIProjectClient(endpoint=endpoint, credential=credential) as project:
        jobs = []
        if args.data_job_id:
            jobs.append(("data", project.datasets.get_generation_job(args.data_job_id)))
        if args.evaluator_job_id:
            jobs.append(("evaluator", project.evaluators.get_generation_job(args.evaluator_job_id)))
        failed = []
        for label, job in jobs:
            print(json.dumps({
                "kind": label,
                "id": job.id,
                "status": job.status,
                "result": job.result.as_dict() if job.result else None,
                "error": job.error.as_dict() if job.error else None,
            }, default=str))
            if job.status in ("failed", "cancelled", "skipped"):
                failed.append(f"{label}: {job.status}")
        if failed:
            raise RuntimeError(f"Generation did not succeed: {', '.join(failed)}.")


def export_artifacts(args: argparse.Namespace, credential: TenantCheckedCredential) -> None:
    agent_name = agent_config()["name"]
    endpoint = project_endpoint(args.account, args.project)
    with AIProjectClient(endpoint=endpoint, credential=credential) as project:
        data = project.datasets.get_generation_job(args.data_job_id)
        evaluator = project.evaluators.get_generation_job(args.evaluator_job_id)
        if data.status != "succeeded" or not data.result or evaluator.status != "succeeded" or not evaluator.result:
            raise RuntimeError("Both generation jobs must succeed before exporting their artifacts.")
        outputs = [output for output in data.result.outputs or [] if output.type == "dataset"]
        if len(outputs) != 1 or not outputs[0].name or not outputs[0].version:
            raise RuntimeError("The data job did not return exactly one versioned dataset.")
        dataset = project.datasets.get(outputs[0].name, outputs[0].version)
        if (
            dataset.name != DATASET_NAME
            or dataset.type != "uri_file"
            or not dataset.tags
            or dataset.tags.get("data_generation_job_id") != args.data_job_id
        ):
            raise RuntimeError("The dataset does not match the requested generation job.")
        if evaluator.result.name != EVALUATOR_NAME or not evaluator.result.version:
            raise RuntimeError("The generation job did not return the expected versioned evaluator.")
        if not all(
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value)
            for value in (agent_name, dataset.version, evaluator.result.version)
        ):
            raise RuntimeError("The agent name or artifact version cannot be used in a cache filename.")
        registered_evaluator = project.evaluators.get_version(evaluator.result.name, evaluator.result.version)
        if registered_evaluator.id != evaluator.result.id or not registered_evaluator.definition:
            raise RuntimeError("The registered evaluator does not match the generation job.")
        blob = project.datasets.get_credentials(dataset.name, dataset.version).blob_reference
        data_uri = urlsplit(dataset.data_uri)
        blob_uri = urlsplit(blob.blob_uri)
        sas_uri = urlsplit(blob.credential.sas_uri)
        if (
            any(uri.scheme != "https" or uri.username or uri.password or uri.fragment for uri in (data_uri, blob_uri, sas_uri))
            or data_uri.hostname != blob_uri.hostname
            or data_uri.hostname != sas_uri.hostname
            or not data_uri.hostname
            or not data_uri.hostname.endswith(".blob.core.windows.net")
            or blob_uri.path != data_uri.path
            or sas_uri.path != data_uri.path
            or len(data_uri.path.strip("/").split("/")) != 1
            or parse_qs(sas_uri.query).get("sr") != ["c"]
        ):
            raise RuntimeError("The dataset storage and credential locations do not match.")
        blob_path = f"{sas_uri.path.rstrip('/')}/{quote(dataset.name + '_dg.jsonl', safe='')}"
        download_url = urlunsplit((sas_uri.scheme, sas_uri.netloc, blob_path, sas_uri.query, ""))
        try:
            with urlopen(download_url, timeout=60) as response:
                content = response.read(10_000_001)
        except HTTPError as exc:
            raise RuntimeError(f"Dataset download failed: HTTP {exc.code}.") from None
        except URLError:
            raise RuntimeError("Dataset download failed due to a connection error.") from None
        if len(content) > 10_000_000:
            raise RuntimeError("The generated dataset exceeds the 10 MB export limit.")
        text = content.decode("utf-8-sig")
        if re.search(r"(?i)(?:[?&]|%3f|%26)sig(?:=|%3d)", text):
            raise RuntimeError("The generated dataset contains a signed URL and cannot be exported.")
        rows = [json.loads(line) for line in text.splitlines() if line.strip()]
        if len(rows) != data.result.generated_samples or not all(isinstance(row, dict) for row in rows):
            raise RuntimeError("The generated dataset does not match the reported sample count or format.")
        if (
            any(
                not isinstance(row.get("id"), int)
                or isinstance(row.get("id"), bool)
                or not isinstance(row.get("query"), str)
                or not row["query"].strip()
                for row in rows
            )
            or len({row["id"] for row in rows}) != len(rows)
        ):
            raise RuntimeError("Generated questions must have unique numeric IDs and non-empty queries.")
        questions_text = "".join(
            json.dumps({"id": row["id"], "query": row["query"]}, ensure_ascii=False) + "\n"
            for row in rows
        )
        evaluator_text = json.dumps(registered_evaluator.as_dict(), ensure_ascii=False, indent=2) + "\n"
        if re.search(r"(?i)(?:[?&]|%3f|%26)sig(?:=|%3d)", evaluator_text):
            raise RuntimeError("The evaluator contains a signed URL and cannot be exported.")

        dataset_stem = f"{agent_name}-{dataset.name}-v{dataset.version}"
        files = {
            args.output_dir / "datasets" / f"{dataset_stem}.jsonl": text.encode("utf-8"),
            args.output_dir / "datasets" / f"{dataset_stem}-questions.jsonl": questions_text.encode("utf-8"),
            args.output_dir / "evaluators" / f"{evaluator.result.name}-v{evaluator.result.version}.json": (
                evaluator_text.encode("utf-8")
            ),
        }
        for path, contents in files.items():
            if path.exists() and path.read_bytes() != contents:
                raise RuntimeError(f"Refusing to overwrite an existing artifact: {path}")
        for path, contents in files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists():
                with path.open("xb") as output:
                    output.write(contents)
            print(f"Exported {path}")
        print(f"Exported {len(rows)} generated samples; content requires review.")


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Generate or inspect Macaw evaluation artifacts.")
    parser.add_argument("--subscription-id", required=True, type=guid)
    parser.add_argument("--tenant-id", required=True, type=guid)
    parser.add_argument("--account", required=True)
    parser.add_argument("--project", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("start")
    create.add_argument("--version", required=True)
    create.add_argument("--model", required=True)
    inspect = commands.add_parser("status")
    inspect.add_argument("--data-job-id")
    inspect.add_argument("--evaluator-job-id")
    artifacts = commands.add_parser("export-artifacts")
    artifacts.add_argument("--data-job-id", required=True)
    artifacts.add_argument("--evaluator-job-id", required=True)
    artifacts.add_argument(
        "--output-dir", type=Path, default=Path(__file__).resolve().parents[1] / ".foundry"
    )
    args = parser.parse_args()
    credential = TenantCheckedCredential(args.subscription_id, args.tenant_id)
    try:
        if args.command == "start":
            start(args, credential)
        elif args.command == "status":
            status(args, credential)
        else:
            export_artifacts(args, credential)
    finally:
        credential.close()


if __name__ == "__main__":
    main()
