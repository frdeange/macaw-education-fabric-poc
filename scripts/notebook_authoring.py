"""Build Fabric-compatible ipynb definitions from cell-marked Python sources."""

from __future__ import annotations

import argparse
import ast
import json
import re
from pathlib import Path
from typing import Any


CELL_MARKER = re.compile(r"^# %%\s*(?:\[([a-z]+)\])?\s*$")


def build_notebook(
    source_path: Path,
    workspace_id: str,
    lakehouse_id: str,
    lakehouse_name: str,
    lakehouse_parameters: dict[str, str],
) -> dict[str, Any]:
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", workspace_id):
        raise ValueError("workspace_id must be a GUID.")
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", lakehouse_id):
        raise ValueError("lakehouse_id must be a GUID.")
    if not lakehouse_name or "\n" in lakehouse_name:
        raise ValueError("lakehouse_name must be a non-empty single-line name.")

    cells: list[dict[str, Any]] = []
    current_type: str | None = None
    current_tag: str | None = None
    current_source: list[str] = []

    def flush_cell() -> None:
        if current_type is None:
            return
        source = list(current_source)
        cell_id = f"cell-{len(cells) + 1}"
        if current_type == "code":
            code = "".join(source)
            for parameter, value in lakehouse_parameters.items():
                placeholder = f'"__{parameter.upper()}__"'
                code = code.replace(placeholder, json.dumps(value))
            if re.search(r"__[A-Z][A-Z0-9_]*__", code):
                raise ValueError(f"{source_path} contains an unresolved notebook parameter.")
            ast.parse(code, filename=str(source_path))
            source = code.splitlines(keepends=True)
            cells.append(
                {
                    "cell_type": "code",
                    "execution_count": None,
                    "id": cell_id,
                    "metadata": {"tags": ["parameters"]}
                    if current_tag == "parameters"
                    else {},
                    "outputs": [],
                    "source": source,
                }
            )
        else:
            cells.append(
                {
                    "cell_type": "markdown",
                    "id": cell_id,
                    "metadata": {},
                    "source": source,
                }
            )

    for line_number, line in enumerate(source_path.read_text(encoding="utf-8").splitlines(keepends=True), 1):
        marker = CELL_MARKER.match(line.rstrip("\r\n"))
        if marker:
            flush_cell()
            marker_type = marker.group(1)
            current_tag = marker_type
            current_type = "markdown" if marker_type == "markdown" else "code"
            current_source = []
            continue
        if current_type is None:
            raise ValueError(f"{source_path}:{line_number}: content before the first '# %%' cell.")
        if current_type == "markdown":
            if line.startswith("# "):
                current_source.append(line[2:])
            elif line.startswith("#"):
                current_source.append(line[1:])
            else:
                current_source.append(line)
        else:
            current_source.append(line)

    flush_cell()
    if not any(cell["cell_type"] == "code" for cell in cells):
        raise ValueError(f"{source_path} contains no code cells.")

    return {
        "cells": cells,
        "metadata": {
            "dependencies": {
                "lakehouse": {
                    "default_lakehouse": lakehouse_id,
                    "default_lakehouse_name": lakehouse_name,
                    "default_lakehouse_workspace_id": workspace_id,
                }
            },
            "kernelspec": {
                "display_name": "Synapse PySpark",
                "language": "python",
                "name": "synapse_pyspark",
            },
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--workspace-id", required=True)
    parser.add_argument("--lakehouse-id", required=True)
    parser.add_argument("--lakehouse-name", required=True)
    parser.add_argument("--bronze-lakehouse-name", required=True)
    parser.add_argument("--silver-lakehouse-name", required=True)
    parser.add_argument("--gold-lakehouse-name", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    notebook = build_notebook(
        args.source,
        args.workspace_id,
        args.lakehouse_id,
        args.lakehouse_name,
        {
            "bronze_lakehouse_name": args.bronze_lakehouse_name,
            "silver_lakehouse_name": args.silver_lakehouse_name,
            "gold_lakehouse_name": args.gold_lakehouse_name,
        },
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(notebook, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
