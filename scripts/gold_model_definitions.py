"""Build focused, unshared Gold semantic-model definitions."""

import base64
import json
import sys


def quote(name):
    return "'" + name.replace("'", "''") + "'"


def column(name, source, kind, description, hidden=False, *, is_key=False,
           data_category=None, format_string=None):
    text = [
        f"\t/// {description}",
        f"\tcolumn {quote(name)}",
        f"\t\tdataType: {kind}",
        f"\t\tsourceColumn: {source}",
        "\t\tsummarizeBy: none",
    ]
    if hidden:
        text.append("\t\tisHidden")
    if is_key:
        text.append("\t\tisKey")
    if data_category:
        text.append(f"\t\tdataCategory: {data_category}")
    if format_string:
        text.append(f"\t\tformatString: {format_string}")
    return "\n".join(text)


def measure(name, expression, description, fmt="#,##0"):
    return "\n".join([
        f"\t/// {description}",
        f"\tmeasure {quote(name)} = {expression}",
        f"\t\tformatString: {fmt}",
    ])


CALENDAR_DATES_MEASURE = (
    "Calendar Dates",
    "COUNTROWS('Date')",
    "Calendar dates, including days without assessments; future dates are not observations.",
    "#,0",
)


DIMENSIONS = {
    "Campus": ("dim_campus", "campus_key", [
        ("Campus", "campus_name", "string", "Fictional campus in the Netherlands."),
        ("City", "city", "string", "City associated with the fictional campus."),
        ("Holiday Region", "holiday_region", "string", "North, Central or South holiday region."),
    ]),
    "Year Level": ("dim_year_level", "year_level_key", [
        ("Year Level", "year_level_name", "string", "Primary group or secondary year."),
        ("Education Stage", "education_stage", "string", "Primary or secondary education."),
    ]),
    "Programme Track": ("dim_programme_track", "track_key", [
        ("Programme Track", "track_name", "string", "Secondary VMBO, HAVO or VWO programme."),
    ]),
    "Department": ("dim_department", "department_key", [
        ("Department", "department_name", "string", "Fictional subject department."),
    ]),
    "Class Section": ("dim_class_section", "class_section_key", [
        ("Section", "section_code", "string", "Fictional class section within a campus and year level."),
    ]),
    "Subject": ("dim_subject", "subject_key", [
        ("Subject", "subject_name", "string", "Subject taught in the fictional curriculum."),
    ]),
    "Date": ("dim_date", "date_key", [
        ("Date", "calendar_date", "dateTime", "Calendar date; scheduled future dates are not observations."),
        ("Year", "calendar_year", "int64", "Calendar year."),
        ("Month", "month_name", "string", "Calendar month name."),
    ]),
}


def fact(entity, description, keys, values, measures):
    return {
        "entity": entity,
        "description": description,
        "keys": keys,
        "values": values,
        "measures": measures,
    }


def guard(tables):
    return " || ".join(f"ISCROSSFILTERED({quote(table)})" for table in tables)


OPERATIONS = {
    "Enrollment": fact(
        "gold_enrollment_detail", "One student enrollment in a class for the snapshot academic year.",
        {"Campus": "campus_key", "Year Level": "year_level_key", "Programme Track": "track_key",
         "Class Section": "class_section_key"},
        [("Student Key", "student_key", "int64")],
        [("Students",
          "IF(ISCROSSFILTERED('Date'), BLANK(), IF(ISCROSSFILTERED('Department') || ISCROSSFILTERED('Subject'), CALCULATE(DISTINCTCOUNT('Enrollment'[Student Key]), TREATAS(VALUES('Subject Enrollment'[Student Key]), 'Enrollment'[Student Key])), DISTINCTCOUNT('Enrollment'[Student Key])))",
          "Distinct snapshot students; department or subject selects enrolled students, not attendance.", "#,##0"),
         ("Classes",
          "IF(ISCROSSFILTERED('Date'), BLANK(), IF(ISCROSSFILTERED('Department') || ISCROSSFILTERED('Subject'), CALCULATE(DISTINCTCOUNT('Enrollment'[Class Section Key]), TREATAS(VALUES('Subject Enrollment'[Student Key]), 'Enrollment'[Student Key])), DISTINCTCOUNT('Enrollment'[Class Section Key])))",
          "Distinct sections containing selected students; subject and department counts can overlap.", "#,##0"),
         ("Average Students per Class", "DIVIDE([Students], [Classes])",
          "Selected distinct students divided by their distinct class sections, not a lesson size.", "0.00")],
    ),
    "Subject Enrollment": fact(
        "gold_subject_enrollment_detail", "One student enrolled in one subject; students may take multiple subjects.",
        {"Campus": "campus_key", "Year Level": "year_level_key", "Programme Track": "track_key",
         "Class Section": "class_section_key", "Department": "department_key", "Subject": "subject_key"},
        [("Student Key", "student_key", "int64")],
        [("Students in Subject",
          "IF(NOT ISCROSSFILTERED('Date'), DISTINCTCOUNT('Subject Enrollment'[Student Key]), BLANK())",
          "Distinct students taking selected subjects; subject subtotals may overlap.", "#,##0")],
    ),
    "Attendance": fact(
        "gold_attendance_detail", "One observed student-day, not attendance at an individual lesson.",
        {"Campus": "campus_key", "Year Level": "year_level_key",
         "Programme Track": "track_key", "Class Section": "class_section_key", "Date": "date_key"},
        [("Student Key", "student_key", "int64"), ("Attendance Status", "attendance_status", "string")],
        [("Observed Attendance Records",
          "IF(ISCROSSFILTERED('Subject'), BLANK(), IF(ISCROSSFILTERED('Department'), CALCULATE(COUNTROWS('Attendance'), TREATAS(VALUES('Subject Enrollment'[Student Key]), 'Attendance'[Student Key])), COUNTROWS('Attendance')))",
          "Observed student-days. A department selects students taking a department subject, not individual lessons.", "#,##0"),
         ("Present or Late",
          "IF(ISCROSSFILTERED('Subject'), BLANK(), IF(ISCROSSFILTERED('Department'), CALCULATE(COUNTROWS('Attendance'), KEEPFILTERS('Attendance'[Attendance Status] IN {\"Present\", \"Late\"}), TREATAS(VALUES('Subject Enrollment'[Student Key]), 'Attendance'[Student Key])), CALCULATE(COUNTROWS('Attendance'), KEEPFILTERS('Attendance'[Attendance Status] IN {\"Present\", \"Late\"}))))",
          "Present or late observed student-days, not individual lessons.", "#,##0"),
         ("Attendance Rate", "DIVIDE([Present or Late], [Observed Attendance Records])",
          "Present plus late divided by observed student-days, not lesson attendance.", "0.00%")],
    ),
    "Planned Timetable": fact(
        "gold_planned_assignment", "One planned recurring weekly teaching assignment, not an observed lesson.",
        {"Campus": "campus_key", "Class Section": "class_section_key",
         "Department": "department_key", "Subject": "subject_key"},
        [("Capacity Exceeded", "is_capacity_exceeded", "boolean"),
         ("Day of Week", "day_of_week", "string")],
        [("Planned Weekly Assignments", f"IF({guard(['Year Level', 'Programme Track', 'Date'])}, BLANK(), COUNTROWS('Planned Timetable'))",
          "Recurring planned weekly assignments, not observed lessons.", "#,##0"),
         ("Planned Capacity Exceedances", f"IF({guard(['Year Level', 'Programme Track', 'Date'])}, BLANK(), CALCULATE(COUNTROWS('Planned Timetable'), 'Planned Timetable'[Capacity Exceeded] = TRUE()))",
          "Planned assignments exceeding room capacity, not actual incidents.", "#,##0")],
    ),
    "Facility Incidents": fact(
        "gold_facility_incident", "One observed synthetic facility incident through the snapshot date.",
        {"Campus": "campus_key"},
        [("Incident Status", "incident_status", "string"),
         ("Incident Category", "category", "string")],
        [("Observed Facility Incidents", f"IF({guard(['Year Level', 'Programme Track', 'Class Section', 'Department', 'Subject', 'Date'])}, BLANK(), COUNTROWS('Facility Incidents'))",
          "Observed incidents through the snapshot; not evidence of a closure cause.", "#,##0")],
    ),
    "Planned Closure Impacts": fact(
        "gold_planned_closure_assignment", "One planned overlap between a room closure and an assignment.",
        {"Campus": "campus_key", "Class Section": "class_section_key",
         "Department": "department_key", "Subject": "subject_key"},
        [("Closure Date", "closure_date", "dateTime")],
        [("Planned Affected Assignments", f"IF({guard(['Year Level', 'Programme Track', 'Date'])}, BLANK(), COUNTROWS('Planned Closure Impacts'))",
          "Planned schedule and closure overlaps; not observed disruptions.", "#,##0")],
    ),
}

OUTCOMES = {
    "Assessment Results": fact(
        "gold_assessment_result_detail", "One observed result for a student and assessment.",
        {"Campus": "campus_key", "Year Level": "year_level_key", "Programme Track": "track_key",
         "Class Section": "class_section_key", "Department": "department_key",
         "Subject": "subject_key", "Date": "date_key"},
        [("Mark", "mark", "decimal"),
         ("Qualitative Outcome", "qualitative_outcome", "string"),
         ("Assessment Period", "assessment_period", "int64")],
        [("Assessment Results", "COUNTROWS('Assessment Results')",
          "Observed assessment results, not enrolled or distinct assessed students.", "#,0"),
         ("Secondary Average Mark", "AVERAGE('Assessment Results'[Mark])",
          "Mean numeric secondary mark; qualitative primary outcomes are excluded.", "0.00"),
         ("Qualitative Outcomes", "COUNTA('Assessment Results'[Qualitative Outcome])",
          "Observed qualitative results, mostly primary, with no numeric mark.", "#,0")],
    ),
}


def build_definition(workspace_id, lakehouse_id, domain):
    facts = OPERATIONS if domain == "operations" else OUTCOMES if domain == "outcomes" else None
    if facts is None:
        raise ValueError(f"Unknown domain: {domain}")
    dimensions = {name for table in facts.values() for name in table["keys"]}
    parts = {
        "definition.pbism": json.dumps({"version": "4.2", "settings": {"qnaEnabled": True}}),
        "definition/database.tmdl": "database\n\tcompatibilityLevel: 1702\n",
        "definition/model.tmdl": "model Model\n\tculture: en-US\n\tdefaultPowerBIDataSourceVersion: powerBI_V3\n\n"
        + "\n".join(f"ref table {quote(name)}" for name in [*sorted(dimensions), *facts]) + "\n",
        "definition/expressions.tmdl": (
            "expression 'Direct Lake Source' =\n"
            "\t\tlet\n"
            f'\t\t    Source = AzureStorage.DataLake("https://onelake.dfs.fabric.microsoft.com/{workspace_id}/{lakehouse_id}", [HierarchicalNavigation=true])\n'
            "\t\tin\n\t\t    Source\n"
        ),
    }
    relationships = []
    for name in sorted(dimensions):
        entity, key, values = DIMENSIONS[name]
        is_outcomes = domain == "outcomes"
        is_outcomes_date = is_outcomes and name == "Date"
        fields = [column("Key", key, "int64", "Internal relationship key.", True,
                         is_key=is_outcomes and name != "Date")]
        fields += [
            column(n, s, t, d,
                   is_key=is_outcomes_date and n == "Date",
                   data_category="City" if is_outcomes and name == "Campus" and n == "City" else None,
                   format_string="yyyy-MM-dd" if is_outcomes_date and n == "Date" else None)
            for n, s, t, d in values
        ]
        if is_outcomes_date:
            entity = "dim_learning_outcomes_date"
            fields.insert(0, measure(*CALENDAR_DATES_MEASURE))
        parts[f"definition/tables/{name}.tmdl"] = table_text(
            name, entity, fields, f"Dimension for {name.lower()} analysis.",
            data_category="Time" if is_outcomes_date else None,
        )
    for name, spec in facts.items():
        fields = []
        for measure_name, expression, description, fmt in spec["measures"]:
            if domain == "operations":
                unrelated_filters = [
                    ("Planned Timetable", "Day of Week"),
                    ("Planned Timetable", "Capacity Exceeded"),
                    ("Facility Incidents", "Incident Status"),
                    ("Facility Incidents", "Incident Category"),
                    ("Planned Closure Impacts", "Closure Date"),
                    ("Attendance", "Attendance Status"),
                ]
                predicates = [
                    f"ISFILTERED({quote(table)}[{field}])"
                    for table, field in unrelated_filters if table != name
                ]
                expression = f"IF({' || '.join(predicates)}, BLANK(), {expression})"
            fields.append(measure(measure_name, expression, description, fmt))
        for dim, source in spec["keys"].items():
            fields.append(column(f"{dim} Key", source, "int64", "Internal relationship key.", True))
            relationships.append(
                f"relationship {quote(name + ' to ' + dim)}\n"
                f"\tfromColumn: {quote(name)}.{quote(dim + ' Key')}\n"
                f"\ttoColumn: {quote(dim)}.{quote('Key')}\n"
            )
        for name_col, source, kind in spec["values"]:
            hidden = (kind == "int64" and name_col != "Assessment Period") or name_col == "Mark"
            fields.append(column(name_col, source, kind, "Source field supporting the measures." if hidden else "Descriptive category or period.", hidden))
        parts[f"definition/tables/{name}.tmdl"] = table_text(name, spec["entity"], fields, spec["description"])
    parts["definition/relationships.tmdl"] = "\n".join(relationships)
    return [{"path": path, "payloadType": "InlineBase64",
             "payload": base64.b64encode(text.encode("utf-8")).decode("ascii")}
            for path, text in parts.items()]


def table_text(name, entity, fields, description, *, data_category=None):
    return (
        f"/// {description}\ntable {quote(name)}\n"
        + (f"\tdataCategory: {data_category}\n" if data_category else "")
        + "\n"
        + "\n\n".join(fields)
        + f"\n\n\tpartition {quote(name)} = entity\n\t\tmode: directLake\n\t\tsource\n"
        + f"\t\t\tentityName: {entity}\n\t\t\tschemaName: dbo\n"
        + "\t\t\texpressionSource: 'Direct Lake Source'\n"
    )


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: gold_model_definitions.py WORKSPACE_ID LAKEHOUSE_ID DOMAIN")
    print(json.dumps(build_definition(*sys.argv[1:])))
