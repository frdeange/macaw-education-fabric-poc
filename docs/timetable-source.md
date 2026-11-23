# Synthetic timetable file source

The timetable is an additional synthetic file source for the medallion
proof of concept. It is not a copy of the SQL database. The local generator
uses only key and calendar columns from allowlisted extracts of the existing
SQL OneLake mirror; it does not connect to SQL or to Fabric.

## Input extracts

Create a local source directory with UTF-8 CSV files containing these columns:

| File | Required columns |
| --- | --- |
| `AcademicYear.csv` | `AcademicYearKey`, `FirstDate`, `LastDate` |
| `Campus.csv` | `CampusKey` |
| `ClassSection.csv` | `ClassSectionKey`, `SchoolUnitKey`, `AcademicYearKey`, `YearLevelKey` |
| `DateDimension.csv` | `DateKey`, `CalendarDate` |
| `Department.csv` | `DepartmentKey` |
| `SchoolCalendar.csv` | `SchoolCalendarKey`, `CampusKey`, `DateKey`, `IsInstructionDay` |
| `SchoolUnit.csv` | `SchoolUnitKey`, `CampusKey`, `EducationStage` |
| `Subject.csv` | `SubjectKey`, `DepartmentKey` |
| `Teacher.csv` | `TeacherKey`, `SchoolUnitKey`, `DepartmentKey` |
| `TeachingAssignment.csv` | `TeachingAssignmentKey`, `ClassSectionKey`, `SubjectKey`, `TeacherKey` |
| `YearLevel.csv` | `YearLevelKey`, `EducationStage` |

Use only these required fields in the extracts; do not include student records,
names, or unrelated columns. Obtain the data from the allowlisted mirror
shortcuts in Bronze, not from a new query to the operational SQL database.
Keep local extracts outside Git and remove them when they are no longer needed.

## Generate a weekly plan

The command requires the observation snapshot date, a Monday after that
snapshot, and a new output path. For example:

```powershell
python .\scripts\generate_timetable.py `
    --source-dir "$env:TEMP\macaw-mirror-extract" `
    --snapshot-date 2026-11-20 `
    --week-start 2026-11-30 `
    --output-file "$env:TEMP\macaw-timetable-2026-11-30.csv"
```

By default the batch ID is derived from the week-start date. Supply
`--batch-id` only when a distinct, stable batch identifier is needed. The
generator refuses to overwrite an existing output file.

## Output contract and limits

The output contains one planned lesson per `TeachingAssignment` in the
selected Monday-to-Friday week, on a campus instructional day. Eight
illustrative local periods per instructional day are available. The placement
is deterministic for the same source extracts, week, and batch ID, and the
generator rejects invalid source keys, missing campus-calendar dates, and
class-section or teacher conflicts.

Every row is marked `ScheduleStatus=Planned` and includes its batch ID,
synthetic source name, source keys, school-calendar key, scheduled local date
and time, and `Europe/Amsterdam` time zone. The output contains no student
keys, personal names, marks, attendance status, or claim that a lesson
occurred. It is a demonstration baseline, not a complete timetable, a national
curriculum, a lesson-frequency recommendation, or an observed event feed.
Room assignments, revision history, and cancellations remain out of scope
until the facilities and change-feed contracts are agreed.

The generator is local-only. No SQL mirror extracts or timetable files have
been collected or uploaded to Fabric, and no Spark processing or live Fabric
validation has been run. A later ingestion step must retain each original
file, record batch and checksum metadata, parse an explicit schema, and
quarantine invalid rows before any Silver transformation.
