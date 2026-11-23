import csv
import contextlib
import io
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import generate_timetable


WEEK_START = date(2026, 11, 30)
SNAPSHOT_DATE = date(2026, 11, 20)
TABLE_FIELDS = {
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


def write_fixture(
    directory: Path,
    *,
    class_rows: list[dict[str, object]] | None = None,
    assignment_rows: list[dict[str, object]] | None = None,
    subject_rows: list[dict[str, object]] | None = None,
    teacher_rows: list[dict[str, object]] | None = None,
    closed_dates: set[date] | None = None,
) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    weekdays = [WEEK_START.fromordinal(WEEK_START.toordinal() + offset) for offset in range(5)]
    tables: dict[str, list[dict[str, object]]] = {
        "AcademicYear": [
            {"AcademicYearKey": 2026, "FirstDate": "2026-08-17", "LastDate": "2027-07-23"}
        ],
        "Campus": [{"CampusKey": 1}],
        "ClassSection": class_rows
        or [
            {
                "ClassSectionKey": 10,
                "SchoolUnitKey": 1,
                "AcademicYearKey": 2026,
                "YearLevelKey": 1,
            },
            {
                "ClassSectionKey": 11,
                "SchoolUnitKey": 1,
                "AcademicYearKey": 2026,
                "YearLevelKey": 1,
            },
        ],
        "DateDimension": [
            {"DateKey": int(day.strftime("%Y%m%d")), "CalendarDate": day.isoformat()}
            for day in weekdays
        ],
        "Department": [{"DepartmentKey": 1}],
        "SchoolCalendar": [
            {
                "SchoolCalendarKey": index,
                "CampusKey": 1,
                "DateKey": int(day.strftime("%Y%m%d")),
                "IsInstructionDay": int(day not in (closed_dates or set())),
            }
            for index, day in enumerate(weekdays, start=1)
        ],
        "SchoolUnit": [{"SchoolUnitKey": 1, "CampusKey": 1, "EducationStage": "Primary"}],
        "Subject": subject_rows
        or [
            {"SubjectKey": 1, "DepartmentKey": 1},
            {"SubjectKey": 2, "DepartmentKey": 1},
        ],
        "Teacher": teacher_rows
        or [
            {"TeacherKey": 1, "SchoolUnitKey": 1, "DepartmentKey": 1},
            {"TeacherKey": 2, "SchoolUnitKey": 1, "DepartmentKey": 1},
        ],
        "TeachingAssignment": assignment_rows
        or [
            {
                "TeachingAssignmentKey": 1001,
                "ClassSectionKey": 10,
                "SubjectKey": 1,
                "TeacherKey": 1,
            },
            {
                "TeachingAssignmentKey": 1002,
                "ClassSectionKey": 11,
                "SubjectKey": 1,
                "TeacherKey": 1,
            },
            {
                "TeachingAssignmentKey": 1003,
                "ClassSectionKey": 10,
                "SubjectKey": 2,
                "TeacherKey": 2,
            },
        ],
        "YearLevel": [{"YearLevelKey": 1, "EducationStage": "Primary"}],
    }
    for table, rows in tables.items():
        with (directory / f"{table}.csv").open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=TABLE_FIELDS[table], lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)


class TimetableGeneratorTests(unittest.TestCase):
    def test_is_repeatable_and_marks_every_event_as_planned(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            write_fixture(source_dir)
            sources = generate_timetable.load_sources(source_dir)

            first = generate_timetable.generate_rows(
                sources, WEEK_START, SNAPSHOT_DATE, "test-week-v1"
            )
            second = generate_timetable.generate_rows(
                sources, WEEK_START, SNAPSHOT_DATE, "test-week-v1"
            )

            self.assertEqual(first, second)
            self.assertEqual(len(first), 3)
            self.assertTrue(all(row["ScheduleStatus"] == "Planned" for row in first))
            self.assertTrue(all(row["TimeZone"] == "Europe/Amsterdam" for row in first))
            self.assertTrue(all("StudentKey" not in row for row in first))
            self.assertTrue(all("AttendanceStatus" not in row for row in first))
            self.assertEqual(len({row["ScheduleEventId"] for row in first}), 3)

            first_file = Path(directory) / "first.csv"
            second_file = Path(directory) / "second.csv"
            generate_timetable.write_rows(first_file, first)
            generate_timetable.write_rows(second_file, second)
            self.assertEqual(first_file.read_bytes(), second_file.read_bytes())

            class_slots = {
                (row["ClassSectionKey"], row["ScheduledDate"], row["StartTimeLocal"])
                for row in first
            }
            teacher_slots = {
                (row["TeacherKey"], row["ScheduledDate"], row["StartTimeLocal"])
                for row in first
            }
            self.assertEqual(len(class_slots), len(first))
            self.assertEqual(len(teacher_slots), len(first))

    def test_skips_campus_closure_dates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            write_fixture(source_dir, closed_dates={WEEK_START})
            sources = generate_timetable.load_sources(source_dir)

            rows = generate_timetable.generate_rows(
                sources, WEEK_START, SNAPSHOT_DATE, "test-week-v1"
            )

            self.assertTrue(all(row["ScheduledDate"] != WEEK_START.isoformat() for row in rows))

    def test_rejects_an_incomplete_weekly_calendar(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            write_fixture(source_dir)
            sources = generate_timetable.load_sources(source_dir)
            sources["SchoolCalendar"].pop()

            with self.assertRaisesRegex(ValueError, "is missing campus 1"):
                generate_timetable.generate_rows(
                    sources, WEEK_START, SNAPSHOT_DATE, "test-week-v1"
                )

    def test_rejects_assignments_with_unknown_foreign_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            assignments = [
                {
                    "TeachingAssignmentKey": 1001,
                    "ClassSectionKey": 10,
                    "SubjectKey": 1,
                    "TeacherKey": 999,
                }
            ]
            write_fixture(source_dir, assignment_rows=assignments)

            with self.assertRaisesRegex(ValueError, "unknown parent key"):
                generate_timetable.load_sources(source_dir)

    def test_rejects_overloaded_class_instead_of_emitting_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            subjects = [{"SubjectKey": key, "DepartmentKey": 1} for key in range(1, 42)]
            teachers = [
                {"TeacherKey": key, "SchoolUnitKey": 1, "DepartmentKey": 1}
                for key in range(1, 42)
            ]
            assignments = [
                {
                    "TeachingAssignmentKey": 1000 + key,
                    "ClassSectionKey": 10,
                    "SubjectKey": key,
                    "TeacherKey": key,
                }
                for key in range(1, 42)
            ]
            write_fixture(
                source_dir,
                assignment_rows=assignments,
                subject_rows=subjects,
                teacher_rows=teachers,
            )
            sources = generate_timetable.load_sources(source_dir)

            with self.assertRaisesRegex(ValueError, "without a class or teacher conflict"):
                generate_timetable.generate_rows(
                    sources, WEEK_START, SNAPSHOT_DATE, "test-week-v1"
                )

    def test_rejects_overloaded_teacher_instead_of_emitting_conflicts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            classes = [
                {
                    "ClassSectionKey": key,
                    "SchoolUnitKey": 1,
                    "AcademicYearKey": 2026,
                    "YearLevelKey": 1,
                }
                for key in range(10, 51)
            ]
            assignments = [
                {
                    "TeachingAssignmentKey": 1000 + key,
                    "ClassSectionKey": key,
                    "SubjectKey": 1,
                    "TeacherKey": 1,
                }
                for key in range(10, 51)
            ]
            write_fixture(
                source_dir,
                class_rows=classes,
                assignment_rows=assignments,
                subject_rows=[{"SubjectKey": 1, "DepartmentKey": 1}],
                teacher_rows=[{"TeacherKey": 1, "SchoolUnitKey": 1, "DepartmentKey": 1}],
            )
            sources = generate_timetable.load_sources(source_dir)

            with self.assertRaisesRegex(ValueError, "without a class or teacher conflict"):
                generate_timetable.generate_rows(
                    sources, WEEK_START, SNAPSHOT_DATE, "test-week-v1"
                )

    def test_requires_a_future_monday_inside_the_academic_year(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            write_fixture(source_dir)
            sources = generate_timetable.load_sources(source_dir)

            with self.assertRaisesRegex(ValueError, "after the observation snapshot"):
                generate_timetable.generate_rows(
                    sources, WEEK_START, date(2026, 11, 30), "test-week-v1"
                )
            with self.assertRaisesRegex(ValueError, "must be a Monday"):
                generate_timetable.generate_rows(
                    sources, date(2026, 12, 1), SNAPSHOT_DATE, "test-week-v1"
                )

    def test_does_not_overwrite_an_existing_batch_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_file = Path(directory) / "timetable.csv"
            output_file.write_text("keep this file", encoding="utf-8")

            with self.assertRaises(FileExistsError):
                generate_timetable.write_rows(output_file, [])

            self.assertEqual(output_file.read_text(encoding="utf-8"), "keep this file")

    def test_cli_writes_a_new_planned_batch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            output_file = Path(directory) / "output" / "timetable.csv"
            write_fixture(source_dir)

            with contextlib.redirect_stdout(io.StringIO()):
                result = generate_timetable.main(
                    [
                        "--source-dir",
                        str(source_dir),
                        "--snapshot-date",
                        SNAPSHOT_DATE.isoformat(),
                        "--week-start",
                        WEEK_START.isoformat(),
                        "--output-file",
                        str(output_file),
                    ]
                )

            self.assertEqual(result, 0)
            with output_file.open(encoding="utf-8", newline="") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(len(rows), 3)
            self.assertEqual({row["ScheduleStatus"] for row in rows}, {"Planned"})


if __name__ == "__main__":
    unittest.main()
