"""Apply the approved Outcomes metadata corrections without replacing other model content."""

import base64
import copy
import json
import re
import sys

from gold_model_definitions import CALENDAR_DATES_MEASURE, measure


DIMENSION_KEYS = {
    "Campus": "campus_key",
    "Class Section": "class_section_key",
    "Department": "department_key",
    "Programme Track": "track_key",
    "Subject": "subject_key",
    "Year Level": "year_level_key",
}


def object_span(text, kind, name):
    escaped = re.escape(name)
    pattern = rf"(?m)^\t{kind} (?:'{escaped}'|{escaped})(?=[ \t]*(?:=|\r?$))[^\r\n]*\r?\n"
    matches = list(re.finditer(pattern, text))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one {kind} {name}.")
    start = matches[0].start()
    following = re.search(r"(?m)^\t(?![\t\r\n])", text[matches[0].end():])
    end = matches[0].end() + following.start() if following else len(text)
    return start, end


def property_matches(text, name, indent):
    pattern = rf"(?m)^\t{{{indent}}}{re.escape(name)}(?:[ \t]*:[ \t]*([^\r\n]*))?[ \t]*\r?$"
    return list(re.finditer(pattern, text))


def set_property(text, name, value, indent, allowed_existing=()):
    matches = property_matches(text, name, indent)
    if len(matches) > 1:
        raise ValueError(f"Duplicate {name} property.")
    expected = "" if value is None else value
    replacement = "\t" * indent + name + (f": {value}" if value is not None else "")
    if matches:
        existing = (matches[0].group(1) or "").strip()
        if existing not in {expected, *allowed_existing}:
            raise ValueError(f"Unexpected {name} value: {existing!r}.")
        if text[matches[0].end() - 1:matches[0].end()] == "\r":
            replacement += "\r"
        return text[:matches[0].start()] + replacement + text[matches[0].end():]
    newline = "\r\n" if "\r\n" in text else "\n"
    first_line_end = text.find("\n")
    if first_line_end < 0:
        raise ValueError("Object declaration must end with a newline.")
    insertion = first_line_end + 1
    return text[:insertion] + replacement + newline + text[insertion:]


def set_object_property(text, kind, name, prop, value, *, source=None, allowed_existing=()):
    start, end = object_span(text, kind, name)
    block = text[start:end]
    if source is not None:
        sources = property_matches(block, "sourceColumn", 2)
        if len(sources) != 1 or (sources[0].group(1) or "").strip() != source:
            raise ValueError(f"Unexpected source column for {name}.")
    block = set_property(block, prop, value, 2, allowed_existing)
    return text[:start] + block + text[end:]


def mark_key(text, name, source):
    text = set_object_property(text, "column", name, "isKey", None, source=source,
                               allowed_existing=("true",))
    if len(property_matches(text, "isKey", 2)) != 1:
        raise ValueError("Each dimension must have exactly one marked key.")
    return text


def ensure_calendar_measure(text):
    declarations = re.findall(r"(?m)^\tmeasure (?:'Calendar Dates'|Calendar Dates)(?=[ \t]*=)", text)
    if len(declarations) > 1:
        raise ValueError("Duplicate Calendar Dates measure.")
    if declarations:
        start, end = object_span(text, "measure", "Calendar Dates")
        block = text[start:end]
        if not re.match(r"^\tmeasure (?:'Calendar Dates'|Calendar Dates)[ \t]*=[ \t]*COUNTROWS\('Date'\)\r?\n", block):
            raise ValueError("Existing Calendar Dates measure has an unexpected expression.")
        return text[:start] + set_property(block, "formatString", "#,0", 2) + text[end:]
    categories = property_matches(text, "dataCategory", 1)
    if len(categories) != 1 or (categories[0].group(1) or "").strip() != "Time":
        raise ValueError("Expected the Date table to be marked as Time.")
    newline = "\r\n" if "\r\n" in text else "\n"
    line_end = text.find("\n", categories[0].end())
    if line_end < 0:
        raise ValueError("Date table category must end with a newline.")
    insertion = line_end + 1
    content = newline + measure(*CALENDAR_DATES_MEASURE).replace("\n", newline) + newline
    return text[:insertion] + content + text[insertion:]


def patch_parts(parts):
    result = copy.deepcopy(parts)
    indexed = {}
    for part in result:
        path = part["path"]
        if path in indexed:
            raise ValueError(f"Duplicate definition part: {path}.")
        indexed[path] = part

    def patch_table(name, transform):
        path = f"definition/tables/{name}.tmdl"
        part = indexed.get(path)
        if part is None or part["payloadType"] != "InlineBase64":
            raise ValueError(f"Missing inline table definition: {path}.")
        text = base64.b64decode(part["payload"], validate=True).decode("utf-8")
        part["payload"] = base64.b64encode(transform(text).encode("utf-8")).decode("ascii")

    for name, source in DIMENSION_KEYS.items():
        patch_table(name, lambda text, source=source: mark_key(text, "Key", source))

    def patch_campus(text):
        return set_object_property(text, "column", "City", "dataCategory", "City", source="city")

    patch_table("Campus", patch_campus)

    def patch_date(text):
        declaration = re.search(r"(?m)^table (?:'Date'|Date)\r?\n", text)
        if not declaration or len(re.findall(r"(?m)^table (?:'Date'|Date)\r?$", text)) != 1:
            raise ValueError("Expected exactly one Date table declaration.")
        text = text[:declaration.start()] + set_property(
            text[declaration.start():], "dataCategory", "Time", 1
        )
        text = mark_key(text, "Date", "calendar_date")
        text = set_object_property(
            text, "column", "Date", "formatString", "yyyy-MM-dd", source="calendar_date"
        )
        text = ensure_calendar_measure(text)
        pattern = r"(?m)^(\t\t\tentityName: )(dim_date|dim_learning_outcomes_date)(\r?)$"
        if len(re.findall(pattern, text)) != 1:
            raise ValueError("Expected exactly one known Date entity.")
        return re.sub(pattern, r"\g<1>dim_learning_outcomes_date\g<3>", text)

    patch_table("Date", patch_date)

    def patch_measures(text):
        for name in ("Assessment Results", "Qualitative Outcomes"):
            text = set_object_property(
                text, "measure", name, "formatString", "#,0", allowed_existing=("#,##0",)
            )
        return text

    patch_table("Assessment Results", patch_measures)
    return result


if __name__ == "__main__":
    print(json.dumps(patch_parts(json.load(sys.stdin))))
