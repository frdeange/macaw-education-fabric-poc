import argparse
import csv
import hashlib
import re
import sys
from collections import Counter
from datetime import date, time, timedelta
from pathlib import Path
from typing import Any


SOURCE_COLUMNS = {
    "AcademicYear": ("AcademicYearKey", "FirstDate", "LastDate"),
    "Campus": ("CampusKey",),
    "ClassSection": (
        "ClassSectionKey",
        "SchoolUnitKey",
        "AcademicYearKey",
        "YearLevelKey",
    ),
    "DateDimension": ("DateKey", "CalendarDate"),
    "Department": ("DepartmentKey",),
    "SchoolCalendar": ("SchoolCalendarKey", "CampusKey", "DateKey", "IsInstructionDay"),
    "SchoolUnit": ("SchoolUnitKey", "CampusKey", "EducationStage"),
    "Subject": ("SubjectKey", "DepartmentKey"),
    "Teacher": ("TeacherKey", "SchoolUnitKey", "DepartmentKey"),
    "TeachingAssignment": (
        "TeachingAssignmentKey",
        "ClassSectionKey",
        "SubjectKey",
        "TeacherKey",
    ),
    "YearLevel": ("YearLevelKey", "EducationStage"),
}
INTEGER_COLUMNS = {
    "AcademicYearKey",
    "CampusKey",
    "ClassSectionKey",
    "DateKey",
    "DepartmentKey",
    "SchoolCalendarKey",
    "SchoolUnitKey",
    "SubjectKey",
    "TeacherKey",
    "TeachingAssignmentKey",
    "YearLevelKey",
}
PERIODS = (
    (time(8, 30), time(9, 20)),
    (time(9, 20), time(10, 10)),
    (time(10, 30), time(11, 20)),
    (time(11, 20), time(12, 10)),
    (time(12, 45), time(13, 35)),
    (time(13, 35), time(14, 25)),
    (time(14, 25), time(15, 15)),
    (time(15, 15), time(16, 5)),
)
OUTPUT_COLUMNS = (
    "BatchId",
    "ScheduleEventId",
    "ScheduleStatus",
    "ScheduledDate",
    "StartTimeLocal",
    "EndTimeLocal",
    "TimeZone",
    "CampusKey",
    "SchoolCalendarKey",
    "SchoolUnitKey",
    "ClassSectionKey",
    "YearLevelKey",
    "TeachingAssignmentKey",
    "SubjectKey",
    "TeacherKey",
    "SourceSystem",
    "ScenarioVersion",
)


def _parse_date(value: str, table: str, line_number: int, column: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise ValueError(f"{table}.csv line {line_number}: invalid {column} {value!r}") from exc


def _parse_bool(value: str, table: str, line_number: int, column: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true"}:
        return True
    if normalized in {"0", "false"}:
        return False
    raise ValueError(f"{table}.csv line {line_number}: invalid {column} {value!r}")


def _read_table(source_dir: Path, table: str) -> list[dict[str, Any]]:
    path = source_dir / f"{table}.csv"
    required = SOURCE_COLUMNS[table]
    with path.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames is None:
            raise ValueError(f"{path} has no CSV header.")
        missing = sorted(set(required) - set(reader.fieldnames))
        if missing:
            raise ValueError(f"{path} is missing required columns: {', '.join(missing)}.")

        rows: list[dict[str, Any]] = []
        for line_number, raw in enumerate(reader, start=2):
            row: dict[str, Any] = {"_line_number": line_number}
            for column in required:
                value = (raw[column] or "").strip()
                if column in INTEGER_COLUMNS:
                    try:
                        row[column] = int(value)
                    except ValueError as exc:
                        raise ValueError(
                            f"{table}.csv line {line_number}: invalid integer "
                            f"{column} {value!r}"
                        ) from exc
                elif column == "IsInstructionDay":
                    row[column] = _parse_bool(value, table, line_number, column)
                elif column in {"FirstDate", "LastDate", "CalendarDate"}:
                    row[column] = _parse_date(value, table, line_number, column)
                else:
                    row[column] = value
            rows.append(row)
    return rows


def _index(rows: list[dict[str, Any]], key: str, table: str) -> dict[int, dict[str, Any]]:
    result: dict[int, dict[str, Any]] = {}
    for row in rows:
        value = row[key]
        if value in result:
            raise ValueError(f"{table} contains duplicate {key} {value}.")
        result[value] = row
    return result


def load_sources(source_dir: Path) -> dict[str, list[dict[str, Any]]]:
    sources = {table: _read_table(source_dir, table) for table in SOURCE_COLUMNS}
    indexes = {
        "AcademicYear": _index(sources["AcademicYear"], "AcademicYearKey", "AcademicYear"),
        "Campus": _index(sources["Campus"], "CampusKey", "Campus"),
        "ClassSection": _index(sources["ClassSection"], "ClassSectionKey", "ClassSection"),
        "DateDimension": _index(sources["DateDimension"], "DateKey", "DateDimension"),
        "Department": _index(sources["Department"], "DepartmentKey", "Department"),
        "SchoolCalendar": _index(
            sources["SchoolCalendar"], "SchoolCalendarKey", "SchoolCalendar"
        ),
        "SchoolUnit": _index(sources["SchoolUnit"], "SchoolUnitKey", "SchoolUnit"),
        "Subject": _index(sources["Subject"], "SubjectKey", "Subject"),
        "Teacher": _index(sources["Teacher"], "TeacherKey", "Teacher"),
        "TeachingAssignment": _index(
            sources["TeachingAssignment"], "TeachingAssignmentKey", "TeachingAssignment"
        ),
        "YearLevel": _index(sources["YearLevel"], "YearLevelKey", "YearLevel"),
    }

    date_by_key = indexes["DateDimension"]
    date_values = [row["CalendarDate"] for row in sources["DateDimension"]]
    if len(set(date_values)) != len(date_values):
        raise ValueError("DateDimension contains duplicate CalendarDate values.")

    for unit in sources["SchoolUnit"]:
        if unit["CampusKey"] not in indexes["Campus"]:
            raise ValueError(f"SchoolUnit {unit['SchoolUnitKey']} has an unknown CampusKey.")
        if unit["EducationStage"] not in {"Primary", "Secondary"}:
            raise ValueError(f"SchoolUnit {unit['SchoolUnitKey']} has an invalid stage.")
    for year_level in sources["YearLevel"]:
        if year_level["EducationStage"] not in {"Primary", "Secondary"}:
            raise ValueError(f"YearLevel {year_level['YearLevelKey']} has an invalid stage.")
    for teacher in sources["Teacher"]:
        if teacher["SchoolUnitKey"] not in indexes["SchoolUnit"]:
            raise ValueError(f"Teacher {teacher['TeacherKey']} has an unknown SchoolUnitKey.")
        if teacher["DepartmentKey"] not in indexes["Department"]:
            raise ValueError(f"Teacher {teacher['TeacherKey']} has an unknown DepartmentKey.")
    for subject in sources["Subject"]:
        if subject["DepartmentKey"] not in indexes["Department"]:
            raise ValueError(f"Subject {subject['SubjectKey']} has an unknown DepartmentKey.")
    for section in sources["ClassSection"]:
        unit = indexes["SchoolUnit"].get(section["SchoolUnitKey"])
        year_level = indexes["YearLevel"].get(section["YearLevelKey"])
        if unit is None or year_level is None:
            raise ValueError(f"ClassSection {section['ClassSectionKey']} has an unknown parent key.")
        if unit["EducationStage"] != year_level["EducationStage"]:
            raise ValueError(f"ClassSection {section['ClassSectionKey']} has mismatched education stages.")
        if section["AcademicYearKey"] not in indexes["AcademicYear"]:
            raise ValueError(
                f"ClassSection {section['ClassSectionKey']} has an unknown AcademicYearKey."
            )

    seen_class_subjects: set[tuple[int, int]] = set()
    for assignment in sources["TeachingAssignment"]:
        section = indexes["ClassSection"].get(assignment["ClassSectionKey"])
        subject = indexes["Subject"].get(assignment["SubjectKey"])
        teacher = indexes["Teacher"].get(assignment["TeacherKey"])
        if section is None or subject is None or teacher is None:
            raise ValueError(
                f"TeachingAssignment {assignment['TeachingAssignmentKey']} has an unknown parent key."
            )
        if section["SchoolUnitKey"] != teacher["SchoolUnitKey"]:
            raise ValueError(
                f"TeachingAssignment {assignment['TeachingAssignmentKey']} assigns a teacher "
                "from another school unit."
            )
        if subject["DepartmentKey"] != teacher["DepartmentKey"]:
            raise ValueError(
                f"TeachingAssignment {assignment['TeachingAssignmentKey']} assigns a teacher "
                "from another department."
            )
        class_subject = (section["ClassSectionKey"], subject["SubjectKey"])
        if class_subject in seen_class_subjects:
            raise ValueError(
                f"ClassSection {section['ClassSectionKey']} has duplicate SubjectKey "
                f"{subject['SubjectKey']} assignments."
            )
        seen_class_subjects.add(class_subject)

    seen_campus_dates: set[tuple[int, date]] = set()
    for calendar_row in sources["SchoolCalendar"]:
        if calendar_row["CampusKey"] not in indexes["Campus"]:
            raise ValueError(
                f"SchoolCalendar {calendar_row['SchoolCalendarKey']} has an unknown CampusKey."
            )
        calendar_date = date_by_key.get(calendar_row["DateKey"])
        if calendar_date is None:
            raise ValueError(
                f"SchoolCalendar {calendar_row['SchoolCalendarKey']} has an unknown DateKey."
            )
        campus_date = (calendar_row["CampusKey"], calendar_date["CalendarDate"])
        if campus_date in seen_campus_dates:
            raise ValueError(
                f"SchoolCalendar has duplicate campus/date {campus_date[0]}/{campus_date[1]}."
            )
        seen_campus_dates.add(campus_date)

    return sources


def generate_rows(
    sources: dict[str, list[dict[str, Any]]],
    week_start: date,
    snapshot_date: date,
    batch_id: str,
) -> list[dict[str, Any]]:
    if week_start.weekday() != 0:
        raise ValueError("week-start must be a Monday.")
    if week_start <= snapshot_date:
        raise ValueError("The planned timetable week must begin after the observation snapshot.")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", batch_id):
        raise ValueError("batch-id must be 1-80 safe ASCII letters, digits, dots, underscores or hyphens.")

    index = {
        "AcademicYear": _index(sources["AcademicYear"], "AcademicYearKey", "AcademicYear"),
        "Campus": _index(sources["Campus"], "CampusKey", "Campus"),
        "ClassSection": _index(sources["ClassSection"], "ClassSectionKey", "ClassSection"),
        "DateDimension": _index(sources["DateDimension"], "DateKey", "DateDimension"),
        "SchoolUnit": _index(sources["SchoolUnit"], "SchoolUnitKey", "SchoolUnit"),
        "Subject": _index(sources["Subject"], "SubjectKey", "Subject"),
        "Teacher": _index(sources["Teacher"], "TeacherKey", "Teacher"),
        "TeachingAssignment": _index(
            sources["TeachingAssignment"], "TeachingAssignmentKey", "TeachingAssignment"
        ),
    }
    if not sources["TeachingAssignment"]:
        raise ValueError("TeachingAssignment has no rows to schedule.")
    academic_year_keys = {
        index["ClassSection"][row["ClassSectionKey"]]["AcademicYearKey"]
        for row in sources["TeachingAssignment"]
    }
    if len(academic_year_keys) != 1:
        raise ValueError("The timetable input must contain assignments from exactly one academic year.")
    academic_year = index["AcademicYear"][next(iter(academic_year_keys))]
    week_dates = [week_start + timedelta(days=offset) for offset in range(5)]
    if any(day < academic_year["FirstDate"] or day > academic_year["LastDate"] for day in week_dates):
        raise ValueError("The planned timetable week is outside the source academic year.")

    date_by_key = index["DateDimension"]
    calendar_by_campus_date: dict[tuple[int, date], dict[str, Any]] = {}
    for row in sources["SchoolCalendar"]:
        calendar_date = date_by_key[row["DateKey"]]["CalendarDate"]
        calendar_by_campus_date[(row["CampusKey"], calendar_date)] = row

    assignments_by_campus: dict[int, list[dict[str, Any]]] = {}
    class_degree: Counter[int] = Counter()
    teacher_degree: Counter[int] = Counter()
    for assignment in sources["TeachingAssignment"]:
        section = index["ClassSection"][assignment["ClassSectionKey"]]
        unit = index["SchoolUnit"][section["SchoolUnitKey"]]
        campus_key = unit["CampusKey"]
        scheduled_assignment = {
            **assignment,
            "CampusKey": campus_key,
            "SchoolUnitKey": section["SchoolUnitKey"],
            "YearLevelKey": section["YearLevelKey"],
        }
        assignments_by_campus.setdefault(campus_key, []).append(scheduled_assignment)
        class_degree[section["ClassSectionKey"]] += 1
        teacher_degree[assignment["TeacherKey"]] += 1

    output: list[dict[str, Any]] = []
    for campus_key, assignments in sorted(assignments_by_campus.items()):
        slots: list[tuple[date, int, time, time, int]] = []
        for day in week_dates:
            calendar_row = calendar_by_campus_date.get((campus_key, day))
            if calendar_row is None:
                raise ValueError(
                    f"SchoolCalendar is missing campus {campus_key} on {day.isoformat()}."
                )
            if calendar_row["IsInstructionDay"]:
                for period_number, (start_time, end_time) in enumerate(PERIODS, start=1):
                    slots.append(
                        (
                            day,
                            period_number,
                            start_time,
                            end_time,
                            calendar_row["SchoolCalendarKey"],
                        )
                    )
        if not slots:
            raise ValueError(f"Campus {campus_key} has no instructional days in the selected week.")

        assignments.sort(
            key=lambda row: (
                -teacher_degree[row["TeacherKey"]],
                -class_degree[row["ClassSectionKey"]],
                row["TeachingAssignmentKey"],
            )
        )
        busy_classes: set[tuple[int, date, int]] = set()
        busy_teachers: set[tuple[int, date, int]] = set()
        for assignment in assignments:
            assignment_key = assignment["TeachingAssignmentKey"]
            candidates = sorted(
                slots,
                key=lambda slot: hashlib.sha256(
                    (
                        f"{batch_id}:{assignment_key}:{slot[0].isoformat()}:{slot[1]}"
                    ).encode("ascii")
                ).digest(),
            )
            selected = None
            for slot in candidates:
                day, period_number, start_time, end_time, calendar_key = slot
                if (
                    (assignment["ClassSectionKey"], day, period_number) not in busy_classes
                    and (assignment["TeacherKey"], day, period_number) not in busy_teachers
                ):
                    selected = slot
                    break
            if selected is None:
                raise ValueError(
                    f"Cannot schedule TeachingAssignment {assignment_key} without a class or "
                    "teacher conflict; reduce the weekly load or add instructional periods."
                )

            day, period_number, start_time, end_time, calendar_key = selected
            busy_classes.add((assignment["ClassSectionKey"], day, period_number))
            busy_teachers.add((assignment["TeacherKey"], day, period_number))
            output.append(
                {
                    "BatchId": batch_id,
                    "ScheduleEventId": f"EVT-{day:%Y%m%d}-{assignment_key:08d}",
                    "ScheduleStatus": "Planned",
                    "ScheduledDate": day.isoformat(),
                    "StartTimeLocal": start_time.isoformat(timespec="minutes"),
                    "EndTimeLocal": end_time.isoformat(timespec="minutes"),
                    "TimeZone": "Europe/Amsterdam",
                    "CampusKey": campus_key,
                    "SchoolCalendarKey": calendar_key,
                    "SchoolUnitKey": assignment["SchoolUnitKey"],
                    "ClassSectionKey": assignment["ClassSectionKey"],
                    "YearLevelKey": assignment["YearLevelKey"],
                    "TeachingAssignmentKey": assignment_key,
                    "SubjectKey": assignment["SubjectKey"],
                    "TeacherKey": assignment["TeacherKey"],
                    "SourceSystem": "SyntheticTimetableGenerator",
                    "ScenarioVersion": "1.0",
                }
            )

    return sorted(
        output,
        key=lambda row: (
            row["ScheduledDate"],
            row["StartTimeLocal"],
            row["CampusKey"],
            row["ClassSectionKey"],
        ),
    )


def write_rows(output_file: Path, rows: list[dict[str, Any]]) -> None:
    output_file.parent.mkdir(parents=True, exist_ok=True)
    with output_file.open("x", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=OUTPUT_COLUMNS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate a deterministic, planned-only synthetic timetable CSV from SQL mirror extracts."
    )
    parser.add_argument("--source-dir", type=Path, required=True, help="Directory containing allowlisted table extracts.")
    parser.add_argument("--week-start", type=date.fromisoformat, required=True, help="Planned Monday in YYYY-MM-DD format.")
    parser.add_argument("--snapshot-date", type=date.fromisoformat, required=True, help="Observation cutoff in YYYY-MM-DD format.")
    parser.add_argument("--batch-id", help="Stable batch identifier; defaults to the week-start date.")
    parser.add_argument("--output-file", type=Path, required=True, help="New CSV path; existing files are never overwritten.")
    args = parser.parse_args(argv)
    batch_id = args.batch_id or f"timetable-{args.week_start.isoformat()}-v1"
    try:
        sources = load_sources(args.source_dir)
        rows = generate_rows(sources, args.week_start, args.snapshot_date, batch_id)
        write_rows(args.output_file, rows)
    except (OSError, ValueError) as exc:
        print(f"Timetable generation failed: {exc}", file=sys.stderr)
        return 1

    print(f"Wrote {len(rows)} planned timetable events to {args.output_file}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
