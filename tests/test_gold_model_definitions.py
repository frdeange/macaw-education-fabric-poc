import base64
import importlib.util
from pathlib import Path

import pytest

path = Path(__file__).parents[1] / "scripts" / "gold_model_definitions.py"
spec = importlib.util.spec_from_file_location("gold_model_definitions", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def decode(domain):
    return {
        part["path"]: base64.b64decode(part["payload"]).decode()
        for part in module.build_definition("workspace", "gold", domain)
    }


def test_operations_distinguishes_department_from_subject_attendance():
    parts = decode("operations")
    attendance = parts["definition/tables/Attendance.tmdl"]
    assert "ISCROSSFILTERED('Subject')" in attendance
    assert "ISCROSSFILTERED('Department')" in attendance
    assert "ISFILTERED('Facility Incidents'[Incident Status])" in attendance
    assert "TREATAS(VALUES('Subject Enrollment'[Student Key]), 'Attendance'[Student Key])" in attendance
    assert "DIVIDE([Present or Late], [Observed Attendance Records])" in attendance
    subject = parts["definition/tables/Subject Enrollment.tmdl"]
    assert "DISTINCTCOUNT('Subject Enrollment'[Student Key])" in subject


def test_outcomes_averages_detailed_marks_and_excludes_qualitative_outcomes():
    parts = decode("outcomes")
    table = parts["definition/tables/Assessment Results.tmdl"]
    assert "AVERAGE('Assessment Results'[Mark])" in table
    assert "entityName: gold_assessment_result_detail" in table
    assert "COUNTA('Assessment Results'[Qualitative Outcome])" in table
    assert "fromColumn: 'Assessment Results'.'Date Key'" in parts["definition/relationships.tmdl"]


def test_outcomes_metadata_marks_unique_dimensions_and_preserves_precision():
    parts = decode("outcomes")
    for name in ("Campus", "Class Section", "Department", "Programme Track", "Subject", "Year Level"):
        table = parts[f"definition/tables/{name}.tmdl"]
        key = table.split("\tcolumn 'Key'\n", 1)[1].split("\n\n", 1)[0]
        assert "\t\tisKey" in key
    campus = parts["definition/tables/Campus.tmdl"]
    city = campus.split("\tcolumn 'City'\n", 1)[1].split("\n\n", 1)[0]
    assert "\t\tdataCategory: City" in city
    date_table = parts["definition/tables/Date.tmdl"]
    date_column = date_table.split("\tcolumn 'Date'\n", 1)[1].split("\n\n", 1)[0]
    assert "\tdataCategory: Time" in date_table
    assert "\t\tisKey" in date_column
    assert "\t\tformatString: yyyy-MM-dd" in date_column
    assert date_table.count("\t\tisKey") == 1
    assert "entityName: dim_learning_outcomes_date" in date_table
    assert "measure 'Calendar Dates' = COUNTROWS('Date')\n\t\tformatString: #,0" in date_table
    table = parts["definition/tables/Assessment Results.tmdl"]
    assert table.count("\t\tformatString: #,0\n") == 2
    assert "AVERAGE('Assessment Results'[Mark])\n\t\tformatString: 0.00" in table
    assert "\tcolumn 'Mark'\n" in table and "\t\tisHidden" in table.split("\tcolumn 'Mark'\n", 1)[1]
    assert "entityName: dim_date" in decode("operations")["definition/tables/Date.tmdl"]


def test_class_sections_are_connected_to_detailed_educational_facts():
    for domain, tables in (
        ("operations", ("Enrollment", "Subject Enrollment", "Attendance", "Planned Timetable",
                        "Planned Closure Impacts")),
        ("outcomes", ("Assessment Results",)),
    ):
        parts = decode(domain)
        relationships = parts["definition/relationships.tmdl"]
        assert "entityName: dim_class_section" in parts["definition/tables/Class Section.tmdl"]
        for table in tables:
            assert f"fromColumn: '{table}'.'Class Section Key'" in relationships
    enrollment = decode("operations")["definition/tables/Enrollment.tmdl"]
    assert "DISTINCTCOUNT('Enrollment'[Class Section Key])" in enrollment
    assert "DIVIDE([Students], [Classes])" in enrollment


def test_operations_use_detailed_schedules_and_keep_attendance_status_filters():
    parts = decode("operations")
    assert "entityName: gold_planned_assignment" in parts["definition/tables/Planned Timetable.tmdl"]
    assert "entityName: gold_facility_incident" in parts["definition/tables/Facility Incidents.tmdl"]
    assert "entityName: gold_planned_closure_assignment" in parts["definition/tables/Planned Closure Impacts.tmdl"]
    attendance = parts["definition/tables/Attendance.tmdl"]
    assert "KEEPFILTERS('Attendance'[Attendance Status] IN" in attendance


def test_unknown_domain_fails():
    with pytest.raises(ValueError):
        module.build_definition("workspace", "gold", "other")
