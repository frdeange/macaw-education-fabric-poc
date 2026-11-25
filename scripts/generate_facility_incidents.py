"""Generate a reproducible, entirely fictional facilities incident snapshot."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from datetime import date
from pathlib import Path
from typing import Any

from generate_timetable import (
    CAMPUSES,
    OBSERVATION_DATE,
    build_assignments,
    build_closures,
    build_rooms,
    build_timetable,
)


BATCH_ID = "facilities-incidents-2026-2027-v1"
DATA_FILE = "facility_incidents_2026_2027.jsonl"
MANIFEST_FILE = "manifest_2026_2027.json"
CATEGORIES = ("Heating", "Lighting", "Ventilation", "Furniture")


def build_incidents() -> list[dict[str, Any]]:
    rooms = build_rooms()
    closures = build_closures(build_timetable(build_assignments()))
    incidents: list[dict[str, Any]] = []
    for index, closure in enumerate(closures):
        reported = f"2026-10-{index + 1:02d}"
        inspected = f"2026-11-{index + 1:02d}"
        incidents.append(
            {
                "id": f"INC-2026-{index + 1:04d}",
                "campusKey": closure["CampusKey"],
                "roomCode": closure["RoomCode"],
                "category": CATEGORIES[index % len(CATEGORIES)],
                "status": "Open",
                "reportedOn": reported,
                "lastUpdatedOn": inspected,
                "observedThrough": OBSERVATION_DATE,
                "sourceVersion": BATCH_ID,
                "events": [
                    {"occurredOn": reported, "eventType": "Reported"},
                    {"occurredOn": inspected, "eventType": "Inspected"},
                ],
            }
        )

    planned_rooms = {(row["CampusKey"], row["RoomCode"]) for row in closures}
    for campus_key in CAMPUSES:
        candidates = [
            room
            for room in rooms
            if room["CampusKey"] == campus_key
            and (room["CampusKey"], room["RoomCode"]) not in planned_rooms
        ][:2]
        if len(candidates) != 2:
            raise ValueError(f"Campus {campus_key} has too few rooms for incidents.")
        for room in candidates:
            number = len(incidents) + 1
            reported = f"2026-09-{number - 10:02d}"
            resolved = f"2026-10-{number - 10:02d}"
            incidents.append(
                {
                    "id": f"INC-2026-{number:04d}",
                    "campusKey": campus_key,
                    "roomCode": room["RoomCode"],
                    "category": CATEGORIES[(number - 1) % len(CATEGORIES)],
                    "status": "Resolved",
                    "reportedOn": reported,
                    "lastUpdatedOn": resolved,
                    "observedThrough": OBSERVATION_DATE,
                    "sourceVersion": BATCH_ID,
                    "events": [
                        {"occurredOn": reported, "eventType": "Reported"},
                        {"occurredOn": resolved, "eventType": "Resolved"},
                    ],
                }
            )
    validate_incidents(incidents)
    return incidents


def validate_incidents(incidents: list[dict[str, Any]]) -> None:
    rooms = {(room["CampusKey"], room["RoomCode"]) for room in build_rooms()}
    snapshot = date.fromisoformat(OBSERVATION_DATE)
    ids: set[str] = set()
    counts: Counter[tuple[int, str]] = Counter()
    if len(incidents) != 20:
        raise ValueError("The facilities snapshot must contain exactly 20 incidents.")

    for incident in incidents:
        incident_id = incident["id"]
        campus_key = incident["campusKey"]
        status = incident["status"]
        if (
            not isinstance(incident_id, str)
            or not incident_id
            or incident_id in ids
            or (campus_key, incident["roomCode"]) not in rooms
            or incident["category"] not in CATEGORIES
            or status not in {"Open", "Resolved"}
            or incident["observedThrough"] != OBSERVATION_DATE
            or incident["sourceVersion"] != BATCH_ID
        ):
            raise ValueError(f"Invalid incident identity, room, category, or status: {incident_id!r}.")
        ids.add(incident_id)
        counts[(campus_key, status)] += 1

        events = incident["events"]
        if not isinstance(events, list) or not events:
            raise ValueError(f"Incident {incident_id} has no history.")
        event_dates = [date.fromisoformat(event["occurredOn"]) for event in events]
        event_types = [event["eventType"] for event in events]
        if (
            event_dates != sorted(event_dates)
            or event_dates[-1] > snapshot
            or event_dates[0].isoformat() != incident["reportedOn"]
            or event_dates[-1].isoformat() != incident["lastUpdatedOn"]
            or event_types[0] != "Reported"
            or (status == "Resolved" and event_types[-1] != "Resolved")
            or (status == "Open" and "Resolved" in event_types)
        ):
            raise ValueError(f"Incident {incident_id} has inconsistent or future events.")
    if counts != Counter(
        {(campus_key, status): 2 for campus_key in CAMPUSES for status in ("Open", "Resolved")}
    ):
        raise ValueError("Each campus must have two open and two resolved incidents.")


def write_dataset(output_dir: Path) -> dict[str, Any]:
    incidents = build_incidents()
    content = "".join(
        json.dumps(incident, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
        for incident in incidents
    ).encode("utf-8")
    manifest = {
        "batchId": BATCH_ID,
        "observationDate": OBSERVATION_DATE,
        "dataFile": DATA_FILE,
        "records": len(incidents),
        "sha256": hashlib.sha256(content).hexdigest(),
    }
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / DATA_FILE).write_bytes(content)
    (output_dir / MANIFEST_FILE).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\r\n",
    )
    return manifest


def read_dataset(output_dir: Path) -> list[dict[str, Any]]:
    manifest = json.loads((output_dir / MANIFEST_FILE).read_text(encoding="utf-8"))
    content = (output_dir / DATA_FILE).read_bytes()
    if (
        manifest["batchId"] != BATCH_ID
        or manifest["observationDate"] != OBSERVATION_DATE
        or manifest["dataFile"] != DATA_FILE
        or manifest["sha256"] != hashlib.sha256(content).hexdigest()
    ):
        raise ValueError("The facilities incident manifest does not match the data file.")
    incidents = [json.loads(line) for line in content.splitlines()]
    if manifest["records"] != len(incidents):
        raise ValueError("The incident count does not match the manifest.")
    validate_incidents(incidents)
    if incidents != build_incidents():
        raise ValueError("The incident data does not match the deterministic seed.")
    return incidents


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "data" / "sources" / "cosmos",
    )
    args = parser.parse_args()
    manifest = write_dataset(args.output_dir)
    print(f"Generated {manifest['records']} fictional incident documents.")


if __name__ == "__main__":
    main()
