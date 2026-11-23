import csv
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFERENCE_FILE = ROOT / "fabric" / "school-holidays-2026-2027.csv"
DATA_URL = "https://opendata.rijksoverheid.nl/v1/infotypes/schoolholidays/schoolyear/2026-2027"
PAGE_URL = (
    "https://www.rijksoverheid.nl/themas/onderwijs/schoolvakanties/"
    "overzicht-schoolvakanties-per-schooljaar/overzicht-schoolvakanties-2026-2027"
)
LAST_MODIFIED = "2025-05-07T06:58:41.060Z"
EXPECTED_DATES = {
    ("North", "Autumn holiday"): ("2026-10-10", "2026-10-18"),
    ("North", "Christmas holiday"): ("2026-12-19", "2027-01-03"),
    ("North", "Spring holiday"): ("2027-02-20", "2027-02-28"),
    ("North", "May holiday"): ("2027-04-24", "2027-05-02"),
    ("North", "May holiday extension advice"): ("2027-05-01", "2027-05-09"),
    ("North", "Summer holiday"): ("2027-07-10", "2027-08-22"),
    ("Central", "Autumn holiday"): ("2026-10-17", "2026-10-25"),
    ("Central", "Christmas holiday"): ("2026-12-19", "2027-01-03"),
    ("Central", "Spring holiday"): ("2027-02-20", "2027-02-28"),
    ("Central", "May holiday"): ("2027-04-24", "2027-05-02"),
    ("Central", "May holiday extension advice"): ("2027-05-01", "2027-05-09"),
    ("Central", "Summer holiday"): ("2027-07-17", "2027-08-29"),
    ("South", "Autumn holiday"): ("2026-10-17", "2026-10-25"),
    ("South", "Christmas holiday"): ("2026-12-19", "2027-01-03"),
    ("South", "Spring holiday"): ("2027-02-13", "2027-02-21"),
    ("South", "May holiday"): ("2027-04-24", "2027-05-02"),
    ("South", "May holiday extension advice"): ("2027-05-01", "2027-05-09"),
    ("South", "Summer holiday"): ("2027-07-24", "2027-09-05"),
}


class SchoolHolidayReferenceTests(unittest.TestCase):
    def test_extract_matches_official_dates_and_status(self) -> None:
        with REFERENCE_FILE.open(encoding="utf-8-sig", newline="") as stream:
            rows = list(csv.DictReader(stream))

        self.assertEqual(len(rows), 18)
        actual = {
            (row["Region"], row["HolidayName"]): (row["StartDate"], row["EndDate"])
            for row in rows
        }
        self.assertEqual(actual, EXPECTED_DATES)
        self.assertEqual(
            {(row["SchoolYear"], row["Region"], row["HolidayName"]) for row in rows},
            {("2026-2027", region, name) for region, name in EXPECTED_DATES},
        )

        for row in rows:
            expected_status = (
                "Compulsory"
                if row["HolidayName"] in {"Christmas holiday", "Summer holiday"}
                else "Advisory"
            )
            self.assertEqual(row["DateStatus"], expected_status)
            self.assertEqual(row["SourceLastModifiedUtc"], LAST_MODIFIED)
            self.assertEqual(row["SourceDataUrl"], DATA_URL)
            self.assertEqual(row["OfficialPageUrl"], PAGE_URL)

    def test_preserves_optional_may_extension_separately(self) -> None:
        with REFERENCE_FILE.open(encoding="utf-8-sig", newline="") as stream:
            rows = list(csv.DictReader(stream))
        extensions = [row for row in rows if row["HolidayName"] == "May holiday extension advice"]

        self.assertEqual({row["Region"] for row in extensions}, {"North", "Central", "South"})
        self.assertTrue(all(row["DateStatus"] == "Advisory" for row in extensions))
        self.assertTrue(all("Optional extension advice" in row["Notes"] for row in extensions))


if __name__ == "__main__":
    unittest.main()
