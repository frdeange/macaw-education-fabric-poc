# Dutch school-holiday reference: 2026-2027

[`school-holidays-2026-2027.csv`](../fabric/school-holidays-2026-2027.csv)
is a versioned reference extract from the Dutch Ministry of Education,
Culture and Science (OCW). Its grain is one row per school year, region, and
published holiday period. Holidays with the same dates in several regions are
repeated by region to support direct joins to campus holiday-region values.

The CSV preserves both English business labels and the Dutch source labels,
the source's last-modified timestamp, and links to the official data and
human-readable page. The source record lists the data under CC0 1.0 Universal.
`DateStatus` maps the official `compulsorydates` value:
`Compulsory` for the Christmas and summer periods, and `Advisory` for the
autumn, spring, May, and optional May-extension advice.

`StartDate` and `EndDate` are inclusive local calendar dates as displayed on
the official holiday page. The underlying data API encodes end times in UTC;
do not treat that timestamp's UTC date as the local inclusive end date. The
separate 1-9 May extension row preserves OCW's advice to extend the base
24 April-2 May holiday. It overlaps the base period by design and is not an
additional observed closure.

Advisory dates are not a school-specific calendar. Schools may deviate, and
the official guidance is to check the school's own guide. The extract is
reference data, not evidence that a fictional campus closed, and it does not
replace or silently alter the existing synthetic `SchoolCalendar`. A future
Silver comparison should report differences for review, not overwrite the
campus calendar.

The row values are checked offline by
[`test_school_holiday_reference.py`](../tests/test_school_holiday_reference.py).
No network refresh, Fabric upload, or Spark processing is performed by that
test.

## Official sources

- [Official school-holiday page for 2026-2027](https://www.rijksoverheid.nl/themas/onderwijs/schoolvakanties/overzicht-schoolvakanties-per-schooljaar/overzicht-schoolvakanties-2026-2027)
- [Official open-data record for 2026-2027](https://opendata.rijksoverheid.nl/v1/infotypes/schoolholidays/schoolyear/2026-2027)
