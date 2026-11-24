"""Generate deterministic fictional timetable, holiday, and HorizonDB seed data."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


ACADEMIC_YEAR = "2026-2027"
ACADEMIC_YEAR_START = "2026-08-17"
ACADEMIC_YEAR_END = "2027-07-23"
OBSERVATION_DATE = "2026-11-20"
TIMETABLE_BATCH_ID = "timetable-2026-2027-v2"
HOLIDAY_SOURCE_URL = (
    "https://www.rijksoverheid.nl/themas/onderwijs/schoolvakanties/"
    "overzicht-schoolvakanties-per-schooljaar/"
    "overzicht-schoolvakanties-2026-2027"
)
PRIOR_HOLIDAY_SOURCE_URL = (
    "https://www.government.nl/themes/education/school-holidays/"
    "overview-of-school-holiday-dates-per-academic-year/"
    "school-holiday-dates-2025-2026"
)
HOLIDAY_RETRIEVED_DATE = "2026-11-23"

CAMPUSES = {
    1: {"city": "Amsterdam", "code": "AMS", "region": "North", "source_region": "Regio Noord"},
    2: {"city": "Utrecht", "code": "UTR", "region": "Central", "source_region": "Regio Midden"},
    3: {"city": "Rotterdam", "code": "RTM", "region": "Central", "source_region": "Regio Midden"},
    4: {"city": "Eindhoven", "code": "EIN", "region": "South", "source_region": "Regio Zuid"},
    5: {"city": "Groningen", "code": "GRN", "region": "North", "source_region": "Regio Noord"},
}

SUBJECT_DEPARTMENTS = {
    1: 1, 2: 2, 3: 5, 4: 6, 5: 1, 6: 1, 7: 2, 8: 4, 9: 3, 10: 5, 11: 6,
    12: 3, 13: 3, 14: 3, 15: 4, 16: 4, 17: 4, 18: 1, 19: 1, 20: 4, 21: 5,
}

SUBJECT_NAMES = {
    1: "Early Language and Literacy",
    2: "Early Numeracy and Patterns",
    3: "Learning Through Play",
    4: "Movement",
    5: "Dutch",
    6: "English",
    7: "Mathematics",
    8: "Social and Environmental Studies",
    9: "Science and Technology",
    10: "Creative Arts",
    11: "Physical Education",
    12: "Biology",
    13: "Physics",
    14: "Chemistry",
    15: "History",
    16: "Geography",
    17: "Economics",
    18: "German",
    19: "French",
    20: "Social Studies",
    21: "Culture and Arts",
}

DAY_NAMES = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
PERIOD_TIMES = (
    ("08:15", "09:00"),
    ("09:10", "09:55"),
    ("10:10", "10:55"),
    ("11:05", "11:50"),
    ("12:30", "13:15"),
    ("13:25", "14:10"),
    ("14:20", "15:05"),
    ("15:15", "16:00"),
)

TIMETABLE_FIELDS = (
    "ScheduleId",
    "TeachingAssignmentKey",
    "ClassSectionKey",
    "CampusKey",
    "SubjectKey",
    "TeacherKey",
    "RoomCode",
    "DayOfWeek",
    "PeriodNumber",
    "StartTime",
    "EndTime",
    "EffectiveStartDate",
    "EffectiveEndDate",
    "RecurrencePattern",
    "ScheduleStatus",
)

HOLIDAY_FIELDS = (
    "Region",
    "SourceRegion",
    "HolidayName",
    "StartDate",
    "EndDate",
    "DateStatus",
    "IsAdvisory",
    "SchoolYear",
    "SourceUrl",
    "RetrievedDate",
)

ROOM_FIELDS = ("RoomKey", "CampusKey", "RoomCode", "RoomType", "Capacity")
CLOSURE_FIELDS = (
    "ClosureKey",
    "CampusKey",
    "RoomCode",
    "ClosureDate",
    "ClosureReason",
    "Status",
    "SourceVersion",
)


def _track_and_profile(year_level: int, section_code: str, student_key: int) -> tuple[int | None, int | None]:
    if year_level <= 8:
        return None, None

    secondary_level = year_level - 8
    if secondary_level <= 4:
        track_key = 1 if section_code in ("A", "D") else 2 if section_code == "B" else 3
    elif secondary_level == 5:
        track_key = 2 if section_code in ("A", "B") else 3
    else:
        track_key = 3

    if track_key in (2, 3) and secondary_level >= 4:
        profile_key = ((student_key - 1) % 4) + 1
    elif track_key == 1 and secondary_level >= 3:
        profile_key = ((student_key - 1) % 4) + 5
    else:
        profile_key = None
    return track_key, profile_key


def _subjects_for_student(
    year_level: int,
    track_key: int | None,
    profile_key: int | None,
) -> set[int]:
    if year_level <= 8:
        if year_level <= 2:
            return {1, 2, 3, 4}
        subjects = {5, 7, 8, 9, 10, 11}
        if year_level >= 5:
            subjects.add(6)
        return subjects

    secondary_level = year_level - 8
    subjects = {5, 6, 7, 11, 20, 21}
    if secondary_level <= 3:
        subjects.update({9, 10, 12, 15, 16})
    if secondary_level in (2, 3) and track_key in (2, 3):
        subjects.add(18)
    if track_key == 1 and secondary_level >= 3:
        subjects.update(
            {
                5: {9, 13, 14},
                6: {12},
                7: {17, 18},
                8: {9, 12},
            }[profile_key]
        )
    if track_key in (2, 3) and secondary_level >= 4:
        subjects.update(
            {
                1: {9, 13, 14},
                2: {12, 14},
                3: {15, 17},
                4: {15, 19},
            }[profile_key]
        )
    if track_key == 3 and secondary_level >= 4:
        subjects.add(18)
    return subjects


def build_assignments() -> list[dict[str, int | str]]:
    class_subjects: dict[int, set[int]] = defaultdict(set)
    class_context: dict[int, dict[str, int | str]] = {}

    for campus_key in CAMPUSES:
        for year_level in range(1, 15):
            school_unit_key = (campus_key - 1) * 2 + (1 if year_level <= 8 else 2)
            for section_number, section_code in enumerate("ABCD", start=1):
                class_section_key = (
                    (campus_key - 1) * 56 + (year_level - 1) * 4 + section_number
                )
                class_context[class_section_key] = {
                    "campus_key": campus_key,
                    "school_unit_key": school_unit_key,
                    "year_level_key": year_level,
                    "section_code": section_code,
                }
                for student_number in range(1, 21):
                    student_key = (class_section_key - 1) * 20 + student_number
                    track_key, profile_key = _track_and_profile(
                        year_level, section_code, student_key
                    )
                    class_subjects[class_section_key].update(
                        _subjects_for_student(year_level, track_key, profile_key)
                    )

    assignments: list[dict[str, int | str]] = []
    for class_section_key in sorted(class_subjects):
        context = class_context[class_section_key]
        for subject_key in sorted(class_subjects[class_section_key]):
            department_key = SUBJECT_DEPARTMENTS[subject_key]
            teacher_sequence = ((subject_key - 1) % 4) + 1
            teacher_key = (
                (int(context["school_unit_key"]) - 1) * 24
                + (department_key - 1) * 4
                + teacher_sequence
            )
            assignments.append(
                {
                    "TeachingAssignmentKey": len(assignments) + 1,
                    "ClassSectionKey": class_section_key,
                    "CampusKey": int(context["campus_key"]),
                    "SubjectKey": subject_key,
                    "TeacherKey": teacher_key,
                    "YearLevelKey": int(context["year_level_key"]),
                    "SectionCode": str(context["section_code"]),
                    "SubjectName": SUBJECT_NAMES[subject_key],
                }
            )
    return assignments


def build_timetable(assignments: list[dict[str, int | str]]) -> list[dict[str, Any]]:
    slots = [
        (day_number, period_number)
        for day_number in range(1, len(DAY_NAMES) + 1)
        for period_number in range(1, len(PERIOD_TIMES) + 1)
    ]
    teacher_slots: set[tuple[int, int, int]] = set()
    section_slots: set[tuple[int, int, int]] = set()
    room_slots: set[tuple[str, int, int]] = set()
    rows = []

    for assignment in assignments:
        campus = CAMPUSES[int(assignment["CampusKey"])]
        local_section_number = (int(assignment["ClassSectionKey"]) - 1) % 56 + 1
        room_code = f"{campus['code']}-R{local_section_number:03d}"
        assignment_key = int(assignment["TeachingAssignmentKey"])
        candidates = sorted(
            slots,
            key=lambda slot: hashlib.sha256(
                f"{assignment_key}:{slot[0]}:{slot[1]}".encode("ascii")
            ).digest(),
        )
        selected = None
        for day_number, period_number in candidates:
            teacher_slot = (int(assignment["TeacherKey"]), day_number, period_number)
            section_slot = (
                int(assignment["ClassSectionKey"]),
                day_number,
                period_number,
            )
            room_slot = (room_code, day_number, period_number)
            if (
                teacher_slot not in teacher_slots
                and section_slot not in section_slots
                and room_slot not in room_slots
            ):
                selected = (day_number, period_number)
                teacher_slots.add(teacher_slot)
                section_slots.add(section_slot)
                room_slots.add(room_slot)
                break
        if selected is None:
            raise ValueError(
                f"No conflict-free weekly slot is available for assignment {assignment_key}."
            )

        day_number, period_number = selected
        start_time, end_time = PERIOD_TIMES[period_number - 1]
        rows.append(
            {
                "ScheduleId": f"SCH-{assignment_key:06d}",
                "TeachingAssignmentKey": assignment_key,
                "ClassSectionKey": int(assignment["ClassSectionKey"]),
                "CampusKey": int(assignment["CampusKey"]),
                "SubjectKey": int(assignment["SubjectKey"]),
                "TeacherKey": int(assignment["TeacherKey"]),
                "RoomCode": room_code,
                "DayOfWeek": DAY_NAMES[day_number - 1],
                "PeriodNumber": period_number,
                "StartTime": start_time,
                "EndTime": end_time,
                "EffectiveStartDate": ACADEMIC_YEAR_START,
                "EffectiveEndDate": ACADEMIC_YEAR_END,
                "RecurrencePattern": "EveryInstructionalWeek",
                "ScheduleStatus": "Planned",
            }
        )
    return rows


def build_holidays() -> list[dict[str, str]]:
    dates_by_region = {
        "North": {
            "Autumn holiday": ("2026-10-10", "2026-10-18", True),
            "Christmas holiday": ("2026-12-19", "2027-01-03", False),
            "Spring holiday": ("2027-02-20", "2027-02-28", True),
            "May holiday": ("2027-04-24", "2027-05-02", False),
            "May holiday extension": ("2027-05-01", "2027-05-09", True),
            "Summer holiday": ("2027-07-10", "2027-08-22", False),
        },
        "Central": {
            "Autumn holiday": ("2026-10-17", "2026-10-25", True),
            "Christmas holiday": ("2026-12-19", "2027-01-03", False),
            "Spring holiday": ("2027-02-20", "2027-02-28", True),
            "May holiday": ("2027-04-24", "2027-05-02", False),
            "May holiday extension": ("2027-05-01", "2027-05-09", True),
            "Summer holiday": ("2027-07-17", "2027-08-29", False),
        },
        "South": {
            "Autumn holiday": ("2026-10-17", "2026-10-25", True),
            "Christmas holiday": ("2026-12-19", "2027-01-03", False),
            "Spring holiday": ("2027-02-13", "2027-02-21", True),
            "May holiday": ("2027-04-24", "2027-05-02", False),
            "May holiday extension": ("2027-05-01", "2027-05-09", True),
            "Summer holiday": ("2027-07-24", "2027-09-05", False),
        },
    }

    source_regions = {
        "North": "Regio Noord",
        "Central": "Regio Midden",
        "South": "Regio Zuid",
    }
    rows = []
    for region, holiday_dates in dates_by_region.items():
        for holiday_name, (start_date, end_date, advisory) in holiday_dates.items():
            rows.append(
                {
                    "Region": region,
                    "SourceRegion": source_regions[region],
                    "HolidayName": holiday_name,
                    "StartDate": start_date,
                    "EndDate": end_date,
                    "DateStatus": "Advisory" if advisory else "Published",
                    "IsAdvisory": str(advisory).lower(),
                    "SchoolYear": ACADEMIC_YEAR,
                    "SourceUrl": HOLIDAY_SOURCE_URL,
                    "RetrievedDate": HOLIDAY_RETRIEVED_DATE,
                }
            )
    prior_summer = {
        "North": ("2026-07-04", "2026-08-16"),
        "Central": ("2026-07-18", "2026-08-30"),
        "South": ("2026-07-11", "2026-08-23"),
    }
    for region, (start_date, end_date) in prior_summer.items():
        rows.append(
            {
                "Region": region,
                "SourceRegion": source_regions[region],
                "HolidayName": "Summer holiday (previous school year)",
                "StartDate": start_date,
                "EndDate": end_date,
                "DateStatus": "Published",
                "IsAdvisory": "false",
                "SchoolYear": "2025-2026",
                "SourceUrl": PRIOR_HOLIDAY_SOURCE_URL,
                "RetrievedDate": HOLIDAY_RETRIEVED_DATE,
            }
        )
    return rows


def build_rooms() -> list[dict[str, int | str]]:
    rows = []
    for campus_key, campus in CAMPUSES.items():
        for room_number in range(1, 61):
            if room_number <= 56:
                room_type, capacity = "Classroom", 24
            elif room_number <= 58:
                room_type, capacity = "ScienceLab", 28
            else:
                room_type, capacity = "ArtStudio", 24
            rows.append(
                {
                    "RoomKey": (campus_key - 1) * 60 + room_number,
                    "CampusKey": campus_key,
                    "RoomCode": f"{campus['code']}-R{room_number:03d}",
                    "RoomType": room_type,
                    "Capacity": capacity,
                }
            )
    return rows


def build_closures(timetable: list[dict[str, Any]]) -> list[dict[str, int | str]]:
    tuesday_rooms: dict[int, set[str]] = defaultdict(set)
    for row in timetable:
        if row["DayOfWeek"] == "Tuesday":
            tuesday_rooms[row["CampusKey"]].add(row["RoomCode"])

    closure_dates = ("2027-03-02", "2027-04-06")
    rows = []
    for campus_key in CAMPUSES:
        candidate_rooms = sorted(tuesday_rooms[campus_key])
        if len(candidate_rooms) < len(closure_dates):
            raise ValueError(f"Campus {campus_key} has too few Tuesday timetable rooms.")
        for index, (room_code, closure_date) in enumerate(
            zip(candidate_rooms[: len(closure_dates)], closure_dates, strict=True),
            start=1,
        ):
            rows.append(
                {
                    "ClosureKey": len(rows) + 1,
                    "CampusKey": campus_key,
                    "RoomCode": room_code,
                    "ClosureDate": closure_date,
                    "ClosureReason": "Planned maintenance",
                    "Status": "Planned",
                    "SourceVersion": TIMETABLE_BATCH_ID,
                }
            )
    return rows


def _write_csv(path: Path, fieldnames: tuple[str, ...], rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _sql_literal(value: int | str) -> str:
    if isinstance(value, int):
        return str(value)
    return "'" + value.replace("'", "''") + "'"


def _write_horizondb_seed(path: Path, rooms: list[dict[str, Any]], closures: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "-- Generated by scripts/generate_timetable.py; do not edit by hand.",
        "-- Apply only to the project HorizonDB item after reviewing its target.",
        "BEGIN;",
        "INSERT INTO public.facility_room (room_key, campus_key, room_code, room_type, capacity)",
        "VALUES",
    ]
    room_values = [
        "    (" + ", ".join(_sql_literal(row[field]) for field in ROOM_FIELDS) + ")"
        for row in rooms
    ]
    lines.append(",\n".join(room_values))
    lines.append(";")
    lines.extend(
        [
            "",
            "INSERT INTO public.facility_closure (",
            "    closure_key, campus_key, room_code, closure_date, closure_reason, status, source_version",
            ")",
            "VALUES",
        ]
    )
    closure_values = []
    for row in closures:
        values = [
            row["ClosureKey"],
            row["CampusKey"],
            row["RoomCode"],
            f"DATE '{row['ClosureDate']}'",
            row["ClosureReason"],
            row["Status"],
            row["SourceVersion"],
        ]
        closure_values.append("    (" + ", ".join(
            value if isinstance(value, str) and value.startswith("DATE ") else _sql_literal(value)
            for value in values
        ) + ")")
    lines.append(",\n".join(closure_values))
    lines.append(";")
    lines.append("COMMIT;")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\r\n")


def generate_dataset(output_root: Path) -> dict[str, Any]:
    assignments = build_assignments()
    timetable = build_timetable(assignments)
    holidays = build_holidays()
    rooms = build_rooms()
    closures = build_closures(timetable)
    if len(assignments) != 2485 or len({row["ClassSectionKey"] for row in assignments}) != 280:
        raise ValueError("The generated timetable does not match the reviewed SQL teaching-assignment snapshot.")
    if len(holidays) != 21 or len(rooms) != 300 or len(closures) != 10:
        raise ValueError("Generated source counts differ from the documented initial dataset.")

    paths = {
        "timetable": output_root / "timetable" / "timetable_2026_2027.csv",
        "holidays": output_root / "calendar" / "dutch_school_holidays_2026_2027.csv",
        "rooms": output_root / "horizondb" / "facility_rooms_2026_2027.csv",
        "closures": output_root / "horizondb" / "facility_closures_2026_2027.csv",
    }
    _write_csv(paths["timetable"], TIMETABLE_FIELDS, timetable)
    _write_csv(paths["holidays"], HOLIDAY_FIELDS, holidays)
    _write_csv(paths["rooms"], ROOM_FIELDS, rooms)
    _write_csv(paths["closures"], CLOSURE_FIELDS, closures)

    _write_horizondb_seed(
        output_root.parent.parent / "postgres" / "horizondb_seed.sql",
        rooms,
        closures,
    )

    manifest = {
        "batchId": TIMETABLE_BATCH_ID,
        "academicYear": ACADEMIC_YEAR,
        "observationDate": OBSERVATION_DATE,
        "scheduleSemantics": (
            "Planned weekly recurrence; it does not represent an observed lesson or attendance."
        ),
        "assignmentSource": (
            "Deterministic reconstruction of the reviewed synthetic SQL seed; "
            "validate foreign keys against the SQL mirror before publication."
        ),
        "files": {
            name: {
                "path": str(path.relative_to(output_root)).replace("\\", "/"),
                "rowCount": count,
                "sha256": _sha256(path),
                **({"oneLakePath": one_lake_path} if one_lake_path else {}),
            }
            for name, path, count, one_lake_path in (
                (
                    "timetable",
                    paths["timetable"],
                    len(timetable),
                    f"Files/landing/timetable/{TIMETABLE_BATCH_ID}/timetable_2026_2027.csv",
                ),
                (
                    "regionalHolidays",
                    paths["holidays"],
                    len(holidays),
                    f"Files/landing/calendar/{ACADEMIC_YEAR}/{TIMETABLE_BATCH_ID}/dutch_school_holidays_2026_2027.csv",
                ),
                ("horizonRooms", paths["rooms"], len(rooms), None),
                ("horizonClosures", paths["closures"], len(closures), None),
            )
        },
        "holidayReference": {
            "retrievedDate": HOLIDAY_RETRIEVED_DATE,
            "sourceUrls": [HOLIDAY_SOURCE_URL, PRIOR_HOLIDAY_SOURCE_URL],
            "advisoryDatesPreserved": True,
            "schoolCalendarIsNotRewritten": True,
        },
        "syntheticFacilities": {
            "rooms": len(rooms),
            "plannedRoomClosures": len(closures),
            "sourceVersion": TIMETABLE_BATCH_ID,
        },
    }
    manifest_path = output_root / "timetable" / "manifest_2026_2027.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\r\n",
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("data") / "sources",
        help="Root directory for generated files (default: data/sources).",
    )
    args = parser.parse_args()
    manifest = generate_dataset(args.output_dir)
    for name, details in manifest["files"].items():
        print(f"{name}: {details['rowCount']} rows; SHA-256 {details['sha256']}")


if __name__ == "__main__":
    main()
