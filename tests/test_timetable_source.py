import csv
import hashlib
import re
import sys
import tempfile
import unittest
from pathlib import Path
from datetime import date


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from generate_timetable import build_assignments, generate_dataset


class TimetableSourceTests(unittest.TestCase):
    def test_generated_sources_have_expected_counts_and_consistent_keys(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_root = Path(temporary_directory) / "data" / "sources"
            manifest = generate_dataset(output_root)

            timetable_path = output_root / "timetable" / "timetable_2026_2027.csv"
            holiday_path = output_root / "calendar" / "dutch_school_holidays_2026_2027.csv"
            rooms_path = output_root / "horizondb" / "facility_rooms_2026_2027.csv"
            closures_path = output_root / "horizondb" / "facility_closures_2026_2027.csv"
            with timetable_path.open(encoding="utf-8-sig", newline="") as source:
                timetable = list(csv.DictReader(source))
            with holiday_path.open(encoding="utf-8-sig", newline="") as source:
                holidays = list(csv.DictReader(source))
            with rooms_path.open(encoding="utf-8-sig", newline="") as source:
                rooms = list(csv.DictReader(source))
            with closures_path.open(encoding="utf-8-sig", newline="") as source:
                closures = list(csv.DictReader(source))

            self.assertEqual(len(timetable), 2485)
            self.assertEqual(len({row["TeachingAssignmentKey"] for row in timetable}), 2485)
            self.assertEqual(len({row["ClassSectionKey"] for row in timetable}), 280)
            self.assertEqual(len(holidays), 21)
            self.assertEqual(len(rooms), 300)
            self.assertEqual(len(closures), 10)
            self.assertEqual(manifest["batchId"], "timetable-2026-2027-v2")

            self.assertTrue(all(row["ScheduleStatus"] == "Planned" for row in timetable))
            self.assertTrue(all(row["RecurrencePattern"] == "EveryInstructionalWeek" for row in timetable))
            self.assertTrue(all(row["EffectiveStartDate"] == "2026-08-17" for row in timetable))
            self.assertTrue(all(row["EffectiveEndDate"] == "2027-07-23" for row in timetable))
            self.assertTrue(all(row["IsAdvisory"] in {"true", "false"} for row in holidays))
            self.assertEqual(
                {row["Region"] for row in holidays},
                {"North", "Central", "South"},
            )
            previous_summer = [
                row
                for row in holidays
                if row["HolidayName"] == "Summer holiday (previous school year)"
            ]
            self.assertEqual(len(previous_summer), 3)
            self.assertTrue(all(row["SchoolYear"] == "2025-2026" for row in previous_summer))

            for key in ("TeacherKey", "ClassSectionKey", "RoomCode"):
                occupied = set()
                for row in timetable:
                    slot = (row[key], row["DayOfWeek"], row["PeriodNumber"])
                    self.assertNotIn(slot, occupied, f"Weekly {key} conflict at {slot}.")
                    occupied.add(slot)

            room_codes = {row["RoomCode"] for row in rooms}
            self.assertTrue(all(row["RoomCode"] in room_codes for row in timetable))
            self.assertTrue(all(row["RoomCode"] in room_codes for row in closures))
            self.assertTrue(all(row["Status"] == "Planned" for row in closures))
            self.assertTrue(all(row["ClosureDate"] > "2026-11-20" for row in closures))
            assignments = {
                row["TeachingAssignmentKey"]: row for row in build_assignments()
            }
            for row in timetable:
                assignment = assignments[int(row["TeachingAssignmentKey"])]
                self.assertEqual(int(row["ClassSectionKey"]), assignment["ClassSectionKey"])
                self.assertEqual(int(row["CampusKey"]), assignment["CampusKey"])
                self.assertEqual(int(row["SubjectKey"]), assignment["SubjectKey"])
                self.assertEqual(int(row["TeacherKey"]), assignment["TeacherKey"])
            for closure in closures:
                self.assertEqual(date.fromisoformat(closure["ClosureDate"]).isoweekday(), 2)
                self.assertTrue(
                    any(
                        row["RoomCode"] == closure["RoomCode"]
                        and row["DayOfWeek"] == "Tuesday"
                        for row in timetable
                    )
                )

            for details in manifest["files"].values():
                source_path = output_root / details["path"]
                self.assertEqual(
                    hashlib.sha256(source_path.read_bytes()).hexdigest(),
                    details["sha256"],
                )
            self.assertEqual(
                manifest["files"]["timetable"]["oneLakePath"],
                "Files/landing/timetable/timetable-2026-2027-v2/timetable_2026_2027.csv",
            )
            self.assertEqual(
                manifest["files"]["regionalHolidays"]["oneLakePath"],
                "Files/landing/calendar/2026-2027/timetable-2026-2027-v2/dutch_school_holidays_2026_2027.csv",
            )
            seed_path = output_root.parent.parent / "postgres" / "horizondb_seed.sql"
            seed = seed_path.read_text(encoding="utf-8")
            room_values = seed.split("INSERT INTO public.facility_room", 1)[1].split(
                "INSERT INTO public.facility_closure", 1
            )[0]
            closure_values = seed.split("INSERT INTO public.facility_closure", 1)[1]
            self.assertEqual(len(re.findall(r"^    \(", room_values, re.MULTILINE)), 300)
            self.assertEqual(len(re.findall(r"^    \(", closure_values, re.MULTILINE)), 10)
            self.assertTrue(seed.startswith("-- Generated by scripts/generate_timetable.py"))
            self.assertIn("BEGIN;", seed)
            self.assertTrue(seed.rstrip().endswith("COMMIT;"))
            self.assertNotIn("ON CONFLICT", seed)

            schema = (ROOT / "postgres" / "horizondb_schema.sql").read_text(encoding="utf-8")
            validation = (ROOT / "postgres" / "horizondb_validate.sql").read_text(encoding="utf-8")
            self.assertIn("room_key INTEGER PRIMARY KEY", schema)
            self.assertIn("closure_key INTEGER PRIMARY KEY", schema)
            self.assertIn("CHECK (status = 'Planned')", schema)
            self.assertIn("Expected 300 synthetic rooms.", validation)
            self.assertIn("Expected ten planned room closures.", validation)

    def test_generation_is_byte_for_byte_reproducible(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            first_root = Path(temporary_directory) / "first" / "data" / "sources"
            second_root = Path(temporary_directory) / "second" / "data" / "sources"
            generate_dataset(first_root)
            generate_dataset(second_root)

            relative_paths = (
                Path("timetable") / "timetable_2026_2027.csv",
                Path("timetable") / "manifest_2026_2027.json",
                Path("calendar") / "dutch_school_holidays_2026_2027.csv",
                Path("horizondb") / "facility_rooms_2026_2027.csv",
                Path("horizondb") / "facility_closures_2026_2027.csv",
            )
            for relative_path in relative_paths:
                with self.subTest(path=relative_path):
                    self.assertEqual(
                        (first_root / relative_path).read_bytes(),
                        (second_root / relative_path).read_bytes(),
                    )
                    self.assertEqual(
                        (first_root / relative_path).read_bytes(),
                        (ROOT / "data" / "sources" / relative_path).read_bytes(),
                    )
            self.assertEqual(
                (first_root.parent.parent / "postgres" / "horizondb_seed.sql").read_bytes(),
                (second_root.parent.parent / "postgres" / "horizondb_seed.sql").read_bytes(),
            )
            self.assertEqual(
                (first_root.parent.parent / "postgres" / "horizondb_seed.sql").read_bytes(),
                (ROOT / "postgres" / "horizondb_seed.sql").read_bytes(),
            )


if __name__ == "__main__":
    unittest.main()
