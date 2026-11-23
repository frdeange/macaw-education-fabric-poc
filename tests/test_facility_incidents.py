import copy
import json
import sys
import tempfile
import unittest
from collections import Counter
from datetime import date
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from generate_facility_incidents import (
    DATA_FILE,
    MANIFEST_FILE,
    OBSERVATION_DATE,
    build_incidents,
    read_dataset,
    validate_incidents,
    write_dataset,
)
from generate_timetable import build_assignments, build_closures, build_rooms, build_timetable
from load_cosmos_facilities import synchronize


class FacilityIncidentsTests(unittest.TestCase):
    def test_snapshot_matches_rooms_and_observation_date(self):
        incidents = build_incidents()
        rooms = {(room["CampusKey"], room["RoomCode"]) for room in build_rooms()}
        closures = build_closures(build_timetable(build_assignments()))
        planned_rooms = {(row["CampusKey"], row["RoomCode"]) for row in closures}
        self.assertEqual(len(incidents), 20)
        self.assertEqual(len({incident["id"] for incident in incidents}), 20)
        self.assertEqual(
            Counter((incident["campusKey"], incident["status"]) for incident in incidents),
            Counter({(campus, status): 2 for campus in range(1, 6) for status in ("Open", "Resolved")}),
        )
        self.assertEqual(
            {(incident["campusKey"], incident["roomCode"]) for incident in incidents if incident["status"] == "Open"},
            planned_rooms,
        )
        for incident in incidents:
            self.assertIn((incident["campusKey"], incident["roomCode"]), rooms)
            self.assertNotIn("closureDate", incident)
            for event in incident["events"]:
                self.assertLessEqual(date.fromisoformat(event["occurredOn"]), date.fromisoformat(OBSERVATION_DATE))

    def test_future_or_invalid_incident_is_rejected(self):
        incidents = build_incidents()
        future = copy.deepcopy(incidents)
        future[0]["events"][-1]["occurredOn"] = "2026-11-21"
        future[0]["lastUpdatedOn"] = "2026-11-21"
        with self.assertRaisesRegex(ValueError, "future events"):
            validate_incidents(future)
        wrong_room = copy.deepcopy(incidents)
        wrong_room[0]["campusKey"] = 2
        with self.assertRaisesRegex(ValueError, "identity, room"):
            validate_incidents(wrong_room)

    def test_files_are_reproducible_and_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            first = Path(temporary_directory) / "first"
            second = Path(temporary_directory) / "second"
            write_dataset(first)
            write_dataset(second)
            self.assertEqual((first / DATA_FILE).read_bytes(), (second / DATA_FILE).read_bytes())
            self.assertEqual((first / MANIFEST_FILE).read_bytes(), (second / MANIFEST_FILE).read_bytes())
            self.assertEqual((first / DATA_FILE).read_bytes(), (ROOT / "data" / "sources" / "cosmos" / DATA_FILE).read_bytes())
            self.assertEqual(
                (first / MANIFEST_FILE).read_bytes(),
                (ROOT / "data" / "sources" / "cosmos" / MANIFEST_FILE).read_bytes(),
            )
            self.assertEqual(read_dataset(first), build_incidents())
            with (first / DATA_FILE).open("a", encoding="utf-8") as output:
                output.write(json.dumps({"id": "unexpected"}) + "\n")
            with self.assertRaisesRegex(ValueError, "manifest"):
                read_dataset(first)

    def test_existing_mismatched_cosmos_document_is_never_overwritten(self):
        expected = build_incidents()[:1]
        changed = copy.deepcopy(expected[0])
        changed["status"] = "Resolved"
        container = Mock()
        container.read.return_value = {"id": "FacilityIncidents", "partitionKey": {"paths": ["/campusKey"]}}
        container.get_throughput.return_value = SimpleNamespace(auto_scale_max_throughput=1000)
        container.query_items.return_value = [{"id": changed["id"], "campusKey": changed["campusKey"]}]
        container.read_item.return_value = changed
        with self.assertRaisesRegex(ValueError, "differs from the seed"):
            synchronize(container, expected, verify_only=False)
        container.create_item.assert_not_called()

    def test_verify_only_refuses_missing_cosmos_documents(self):
        container = Mock()
        container.read.return_value = {"id": "FacilityIncidents", "partitionKey": {"paths": ["/campusKey"]}}
        container.get_throughput.return_value = SimpleNamespace(auto_scale_max_throughput=1000)
        container.query_items.return_value = []
        with self.assertRaisesRegex(ValueError, "missing 1 expected incidents"):
            synchronize(container, build_incidents()[:1], verify_only=True)
        container.create_item.assert_not_called()


if __name__ == "__main__":
    unittest.main()
