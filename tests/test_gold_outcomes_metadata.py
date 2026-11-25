import base64
import copy
import importlib.util
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


generator = load_module("gold_model_definitions")
patcher = load_module("patch_gold_outcomes_metadata")


def decode(part):
    return base64.b64decode(part["payload"]).decode("utf-8")


def encode(part, text):
    part["payload"] = base64.b64encode(text.encode("utf-8")).decode("ascii")


@pytest.fixture
def baseline():
    parts = generator.build_definition("workspace", "gold", "outcomes")
    for part in parts:
        path = part["path"]
        text = decode(part)
        if path.startswith("definition/tables/"):
            if path.endswith("/Date.tmdl"):
                text = text.replace(generator.measure(*generator.CALENDAR_DATES_MEASURE) + "\n\n", "")
                text = text.replace("\t\tformatString: yyyy-MM-dd\n", "")
            text = text.replace("\t\tisKey\n", "")
            text = text.replace("\t\tdataCategory: City\n", "")
            text = text.replace("\tdataCategory: Time\n", "")
            text = text.replace("entityName: dim_learning_outcomes_date", "entityName: dim_date")
            text = text.replace("\t\tformatString: #,0\n", "\t\tformatString: #,##0\n")
            text = text.replace("column 'Key'", "column Key")
            text = text.replace("table 'Date'", "table Date").replace("column 'Date'", "column Date")
            text += "\n\tannotation CustomMetadata = preserve\n"
            encode(part, text)
    parts.append({
        "path": "definition/roles/Existing.tmdl",
        "payloadType": "InlineBase64",
        "payload": base64.b64encode(b"existing security metadata").decode("ascii"),
    })
    return parts


def test_patches_only_approved_metadata_and_preserves_other_parts(baseline):
    before = copy.deepcopy(baseline)
    patched = patcher.patch_parts(baseline)
    assert baseline == before
    old = {part["path"]: part for part in before}
    new = {part["path"]: part for part in patched}
    assert old.keys() == new.keys()
    for path in old:
        if not path.startswith("definition/tables/"):
            assert new[path] == old[path]
        else:
            assert "\tannotation CustomMetadata = preserve" in decode(new[path])
    for name in patcher.DIMENSION_KEYS:
        table = decode(new[f"definition/tables/{name}.tmdl"])
        start, end = patcher.object_span(table, "column", "Key")
        assert "\t\tisKey" in table[start:end]
    date_table = decode(new["definition/tables/Date.tmdl"])
    assert "\tdataCategory: Time" in date_table
    date_start, date_end = patcher.object_span(date_table, "column", "Date")
    assert "\t\tformatString: yyyy-MM-dd" in date_table[date_start:date_end]
    assert date_table.count("\t\tisKey") == 1
    assert "entityName: dim_learning_outcomes_date" in date_table
    assert "measure 'Calendar Dates' = COUNTROWS('Date')" in date_table
    campus = decode(new["definition/tables/Campus.tmdl"])
    assert "\t\tdataCategory: City" in campus
    outcome = decode(new["definition/tables/Assessment Results.tmdl"])
    assert outcome.count("\t\tformatString: #,0\n") == 2
    assert "AVERAGE('Assessment Results'[Mark])\n\t\tformatString: 0.00" in outcome
    assert "\tcolumn 'Mark'\n" in outcome
    assert patcher.patch_parts(patched) == patched


@pytest.mark.parametrize(
    ("name", "old", "new"),
    [
        ("Campus", "sourceColumn: campus_key", "sourceColumn: unexpected"),
        ("Campus", "sourceColumn: city", "sourceColumn: city\n\t\tdataCategory: Country"),
        ("Date", "entityName: dim_date", "entityName: another_calendar"),
        ("Date", "sourceColumn: date_key", "sourceColumn: date_key\n\t\tisKey"),
        ("Date", "sourceColumn: calendar_date", "sourceColumn: calendar_date\n\t\tformatString: another-format"),
        ("Date", "table Date\n", "table Date\n\n\tmeasure 'Calendar Dates' = 0\n\t\tformatString: #,0\n"),
        ("Assessment Results", "formatString: #,##0", "formatString: 0%"),
    ],
)
def test_fails_closed_for_unexpected_metadata(baseline, name, old, new):
    path = f"definition/tables/{name}.tmdl"
    part = next(part for part in baseline if part["path"] == path)
    encode(part, decode(part).replace(old, new, 1))
    with pytest.raises(ValueError):
        patcher.patch_parts(baseline)


def test_preserves_crlf_while_changing_existing_formats(baseline):
    paths = ("Assessment Results.tmdl", "Date.tmdl")
    for part in baseline:
        if part["path"].endswith(paths):
            text = decode(part)
            if part["path"].endswith("Date.tmdl"):
                text = text.replace("\tcolumn Date\n", "\tcolumn Date\n\t\tformatString: yyyy-MM-dd\n")
            encode(part, text.replace("\n", "\r\n"))
    patched = patcher.patch_parts(baseline)
    for part in patched:
        if part["path"].endswith(paths):
            assert "\n" not in decode(part).replace("\r\n", "")
