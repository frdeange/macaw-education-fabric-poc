# %% [markdown]
# # Bronze to Silver: SQL mirror snapshot
#
# Read only the allowlisted SQL mirror shortcuts in Bronze, validate the
# educational snapshot, and materialize conformed dimensions and facts in the
# Silver Lakehouse. This notebook does not copy student or teacher names.

# %% [parameters]
# Pipeline-overridable parameters. Keep the expected-count contract aligned
# with fabric/sql-bronze-baseline.json for the currently verified snapshot.
bronze_lakehouse_name = "__BRONZE_LAKEHOUSE_NAME__"
silver_lakehouse_name = "__SILVER_LAKEHOUSE_NAME__"
expected_snapshot_date = "2026-11-20"
batch_id = "sql-mirror-2026-11-20-v1"

expected_counts = {
    "AcademicYear": 1,
    "Assessment": 4970,
    "AssessmentResult": 87100,
    "Attendance": 336000,
    "Campus": 5,
    "ClassSection": 280,
    "DateDimension": 341,
    "Department": 6,
    "EducationProfile": 8,
    "Enrollment": 5600,
    "EnrollmentSubject": 43550,
    "LoadMetadata": 1,
    "ProgrammeTrack": 3,
    "SchoolCalendar": 1705,
    "SchoolUnit": 10,
    "Student": 5600,
    "Subject": 21,
    "Teacher": 240,
    "TeachingAssignment": 2485,
    "YearLevel": 14,
}

# %%
import json
import re
from pyspark.sql import functions as F


SOURCE_KEYS = {
    "AcademicYear": ["AcademicYearKey"],
    "Assessment": ["AssessmentKey"],
    "AssessmentResult": ["AssessmentKey", "EnrollmentKey"],
    "Attendance": ["EnrollmentKey", "SchoolCalendarKey"],
    "Campus": ["CampusKey"],
    "ClassSection": ["ClassSectionKey"],
    "DateDimension": ["DateKey"],
    "Department": ["DepartmentKey"],
    "EducationProfile": ["ProfileKey"],
    "Enrollment": ["EnrollmentKey"],
    "EnrollmentSubject": ["EnrollmentKey", "TeachingAssignmentKey"],
    "LoadMetadata": ["LoadKey"],
    "ProgrammeTrack": ["TrackKey"],
    "SchoolCalendar": ["SchoolCalendarKey"],
    "SchoolUnit": ["SchoolUnitKey"],
    "Student": ["StudentKey"],
    "Subject": ["SubjectKey"],
    "Teacher": ["TeacherKey"],
    "TeachingAssignment": ["TeachingAssignmentKey"],
    "YearLevel": ["YearLevelKey"],
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def assert_key_integrity(frame, columns, table_name):
    null_key = F.col(columns[0]).isNull()
    for column in columns[1:]:
        null_key = null_key | F.col(column).isNull()
    if frame.where(null_key).limit(1).count():
        raise ValueError(f"{table_name} has a null key in {columns}.")
    if frame.groupBy(*columns).count().where(F.col("count") > 1).limit(1).count():
        raise ValueError(f"{table_name} has duplicate keys in {columns}.")


def assert_no_orphans(child, child_column, parent, parent_column, relationship):
    child_keys = child.select(F.col(child_column).alias("_key")).where(F.col("_key").isNotNull())
    parent_keys = parent.select(F.col(parent_column).alias("_key")).dropDuplicates()
    if child_keys.join(parent_keys, "_key", "left_anti").limit(1).count():
        raise ValueError(f"Broken relationship: {relationship}.")


def snake_case(frame):
    names = [re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower() for name in frame.columns]
    require(len(names) == len(set(names)), "Column normalization produced a name collision.")
    return frame.toDF(*names)


def add_lineage(frame):
    return (
        frame.withColumn("_batch_id", F.lit(batch_id))
        .withColumn("_source_snapshot_date", F.lit(source_snapshot_date).cast("date"))
    )


def write_silver(table_name, frame):
    if not re.fullmatch(r"[a-z][a-z0-9_]*", table_name):
        raise ValueError(f"Invalid Silver table name: {table_name}")
    (
        add_lineage(snake_case(frame))
        .write.format("delta")
        .mode("overwrite")
        .option("overwriteSchema", "true")
        .saveAsTable(f"{silver_lakehouse_name}.dbo.{table_name}")
    )


require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", bronze_lakehouse_name) is not None,
        "Invalid Bronze Lakehouse name.")
require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", silver_lakehouse_name) is not None,
        "Invalid Silver Lakehouse name.")
require(set(expected_counts) == set(SOURCE_KEYS), "Expected-count and source-key contracts differ.")
require(batch_id and re.fullmatch(r"[A-Za-z0-9_-]+", batch_id), "Invalid batch_id.")

source_tables = {}
actual_counts = {}
for table_name in sorted(SOURCE_KEYS):
    source_path = f"Files/sql_mirror/{table_name}"
    frame = spark.read.format("delta").load(source_path)
    missing_columns = set(SOURCE_KEYS[table_name]) - set(frame.columns)
    require(not missing_columns, f"{table_name} is missing key columns: {sorted(missing_columns)}.")
    row_count = frame.count()
    require(
        row_count == expected_counts[table_name],
        f"{table_name} row count {row_count} does not match the reviewed snapshot "
        f"baseline {expected_counts[table_name]}.",
    )
    assert_key_integrity(frame, SOURCE_KEYS[table_name], table_name)
    source_tables[table_name] = frame
    actual_counts[table_name] = row_count

metadata_rows = source_tables["LoadMetadata"].select(
    "SnapshotDate", "ScenarioVersion"
).limit(2).collect()
require(len(metadata_rows) == 1, "LoadMetadata must contain exactly one snapshot record.")
source_snapshot_date = metadata_rows[0]["SnapshotDate"].isoformat()
scenario_version = str(metadata_rows[0]["ScenarioVersion"])
require(source_snapshot_date == expected_snapshot_date,
        f"Unexpected source snapshot date: {source_snapshot_date}.")

staging_manifest = spark.createDataFrame(
    [(batch_id, source_snapshot_date, scenario_version, "Staging", json.dumps(actual_counts, sort_keys=True))],
    ["BatchId", "SourceSnapshotDate", "ScenarioVersion", "RunStatus", "SourceRowCountsJson"],
)
(
    staging_manifest.write.format("delta")
    .mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(f"{silver_lakehouse_name}.dbo.silver_batch_manifest")
)

# %%
# Validate core relationships before any curated facts are materialized.
for child_name, child_column, parent_name, parent_column in [
    ("SchoolUnit", "CampusKey", "Campus", "CampusKey"),
    ("ClassSection", "SchoolUnitKey", "SchoolUnit", "SchoolUnitKey"),
    ("ClassSection", "AcademicYearKey", "AcademicYear", "AcademicYearKey"),
    ("ClassSection", "YearLevelKey", "YearLevel", "YearLevelKey"),
    ("Subject", "DepartmentKey", "Department", "DepartmentKey"),
    ("Enrollment", "StudentKey", "Student", "StudentKey"),
    ("Enrollment", "ClassSectionKey", "ClassSection", "ClassSectionKey"),
    ("Enrollment", "TrackKey", "ProgrammeTrack", "TrackKey"),
    ("Enrollment", "ProfileKey", "EducationProfile", "ProfileKey"),
    ("SchoolCalendar", "CampusKey", "Campus", "CampusKey"),
    ("SchoolCalendar", "DateKey", "DateDimension", "DateKey"),
    ("TeachingAssignment", "ClassSectionKey", "ClassSection", "ClassSectionKey"),
    ("TeachingAssignment", "SubjectKey", "Subject", "SubjectKey"),
    ("TeachingAssignment", "TeacherKey", "Teacher", "TeacherKey"),
    ("EnrollmentSubject", "EnrollmentKey", "Enrollment", "EnrollmentKey"),
    ("EnrollmentSubject", "TeachingAssignmentKey", "TeachingAssignment", "TeachingAssignmentKey"),
    ("Assessment", "TeachingAssignmentKey", "TeachingAssignment", "TeachingAssignmentKey"),
    ("Assessment", "DateKey", "DateDimension", "DateKey"),
    ("Attendance", "EnrollmentKey", "Enrollment", "EnrollmentKey"),
    ("Attendance", "SchoolCalendarKey", "SchoolCalendar", "SchoolCalendarKey"),
]:
    assert_no_orphans(
        source_tables[child_name],
        child_column,
        source_tables[parent_name],
        parent_column,
        f"{child_name}.{child_column} -> {parent_name}.{parent_column}",
    )

sections = source_tables["ClassSection"]
enrollments = source_tables["Enrollment"]
school_unit_source = source_tables["SchoolUnit"]
year_level_source = source_tables["YearLevel"]

section_context = (
    sections.alias("cs")
    .join(
        school_unit_source.alias("su"),
        F.col("cs.SchoolUnitKey") == F.col("su.SchoolUnitKey"),
    )
    .join(
        year_level_source.alias("yl"),
        F.col("cs.YearLevelKey") == F.col("yl.YearLevelKey"),
    )
    .select(
        F.col("cs.ClassSectionKey").alias("ClassSectionKey"),
        F.col("cs.SchoolUnitKey").alias("SchoolUnitKey"),
        F.col("su.CampusKey").alias("CampusKey"),
        F.col("su.EducationStage").alias("EducationStage"),
        F.col("yl.EducationStage").alias("YearLevelStage"),
        F.col("cs.AcademicYearKey").alias("AcademicYearKey"),
        F.col("cs.YearLevelKey").alias("YearLevelKey"),
        F.col("yl.LevelNumber").alias("LevelNumber"),
        F.col("cs.SectionCode").alias("SectionCode"),
    )
)

class_sizes = enrollments.groupBy("ClassSectionKey").count()
class_summary = class_sizes.agg(
    F.count("*").alias("ClassCount"),
    F.min("count").alias("MinimumClassSize"),
    F.max("count").alias("MaximumClassSize"),
).first()
require(
    class_summary["ClassCount"] == 280
    and class_summary["MinimumClassSize"] == 20
    and class_summary["MaximumClassSize"] == 20,
    "The current snapshot must contain 280 sections with exactly 20 learners each.",
)

track_durations = {
    row["TrackName"]: row["DurationYears"]
    for row in source_tables["ProgrammeTrack"].select("TrackName", "DurationYears").collect()
}
require(track_durations == {"VMBO": 4, "HAVO": 5, "VWO": 6},
        f"Unexpected programme durations: {track_durations}.")

enrollment_levels = (
    enrollments.join(section_context, "ClassSectionKey")
    .join(source_tables["ProgrammeTrack"], "TrackKey", "left")
)
invalid_track = enrollment_levels.where(
    (F.col("EducationStage") != F.col("YearLevelStage"))
    | ((F.col("EducationStage") == "Primary") & F.col("TrackKey").isNotNull())
    | ((F.col("EducationStage") == "Secondary") & F.col("TrackKey").isNull())
    | (
        (F.col("EducationStage") == "Secondary")
        & (F.col("LevelNumber") > F.col("DurationYears"))
    )
)
require(invalid_track.limit(1).count() == 0,
        "Enrollment contains an ineligible education stage, year level, or track.")

for track_name, duration in track_durations.items():
    represented_years = {
        row["LevelNumber"]
        for row in enrollment_levels.where(F.col("TrackName") == track_name)
        .select("LevelNumber").distinct().collect()
    }
    require(
        set(range(1, duration + 1)).issubset(represented_years),
        f"{track_name} is not represented in every eligible year level.",
    )

assignment_class_mismatch = (
    source_tables["TeachingAssignment"].alias("ta")
    .join(
        sections.alias("cs"),
        F.col("ta.ClassSectionKey") == F.col("cs.ClassSectionKey"),
    )
    .join(
        source_tables["Teacher"].alias("t"),
        F.col("ta.TeacherKey") == F.col("t.TeacherKey"),
    )
    .where(F.col("t.SchoolUnitKey") != F.col("cs.SchoolUnitKey"))
)
require(assignment_class_mismatch.limit(1).count() == 0,
        "A teaching assignment pairs a teacher with a different school unit.")

enrollment_subject_mismatch = (
    source_tables["EnrollmentSubject"].alias("es")
    .join(
        enrollments.alias("e"),
        F.col("es.EnrollmentKey") == F.col("e.EnrollmentKey"),
    )
    .join(
        source_tables["TeachingAssignment"].alias("ta"),
        F.col("es.TeachingAssignmentKey") == F.col("ta.TeachingAssignmentKey"),
    )
    .where(F.col("e.ClassSectionKey") != F.col("ta.ClassSectionKey"))
)
require(enrollment_subject_mismatch.limit(1).count() == 0,
        "A subject enrollment does not match the learner's class section.")

snapshot_date = F.to_date(F.lit(source_snapshot_date))
observed_attendance = (
    source_tables["Attendance"]
    .join(source_tables["SchoolCalendar"], "SchoolCalendarKey")
    .join(source_tables["DateDimension"], "DateKey")
    .where((F.col("CalendarDate") <= snapshot_date) & F.col("IsInstructionDay"))
)
require(
    observed_attendance.count() == 315842,
    "Observed attendance must include only instructional student-days through the snapshot date.",
)

attendance_context = (
    observed_attendance.alias("a")
    .join(
        enrollments.alias("e"),
        F.col("a.EnrollmentKey") == F.col("e.EnrollmentKey"),
    )
    .join(
        section_context.alias("sc"),
        F.col("e.ClassSectionKey") == F.col("sc.ClassSectionKey"),
    )
)
require(
    attendance_context.where(F.col("a.CampusKey") != F.col("sc.CampusKey"))
    .limit(1).count() == 0,
    "An attendance record's campus differs from the learner's enrolled campus.",
)

results = source_tables["AssessmentResult"]
invalid_result = results.where(
    (F.col("Mark").isNull() == F.col("QualitativeOutcome").isNull())
    | (F.col("Mark").isNotNull() & ((F.col("Mark") < 1.0) | (F.col("Mark") > 10.0)))
)
require(invalid_result.limit(1).count() == 0,
        "Assessment results must contain either a 1-to-10 mark or a qualitative outcome.")

stage_result = (
    results.alias("r")
    .join(enrollments.alias("e"), F.col("r.EnrollmentKey") == F.col("e.EnrollmentKey"))
    .join(
        section_context.alias("sc"),
        F.col("e.ClassSectionKey") == F.col("sc.ClassSectionKey"),
    )
    .where(
        ((F.col("sc.EducationStage") == "Primary") & F.col("r.Mark").isNotNull())
        | ((F.col("sc.EducationStage") == "Secondary") & F.col("r.Mark").isNull())
    )
)
require(stage_result.limit(1).count() == 0,
        "Primary results must be qualitative and secondary results must use numeric marks.")

result_assignment_match = results.alias("r").join(
    source_tables["Assessment"].alias("a"),
    (F.col("r.AssessmentKey") == F.col("a.AssessmentKey"))
    & (F.col("r.TeachingAssignmentKey") == F.col("a.TeachingAssignmentKey")),
    "left_anti",
)
require(result_assignment_match.limit(1).count() == 0,
        "An assessment result does not match its assessment assignment.")

result_subject_match = results.alias("r").join(
    source_tables["EnrollmentSubject"].alias("es"),
    (F.col("r.EnrollmentKey") == F.col("es.EnrollmentKey"))
    & (F.col("r.TeachingAssignmentKey") == F.col("es.TeachingAssignmentKey")),
    "left_anti",
)
require(result_subject_match.limit(1).count() == 0,
        "An assessment result does not match the learner's subject enrollment.")

# %%
campus = source_tables["Campus"]
school_unit = source_tables["SchoolUnit"]
academic_year = source_tables["AcademicYear"]
year_level = source_tables["YearLevel"]
track = source_tables["ProgrammeTrack"]
department = source_tables["Department"]
subject = source_tables["Subject"]
date_dimension = source_tables["DateDimension"]
class_section = source_tables["ClassSection"]
student = source_tables["Student"]
teacher = source_tables["Teacher"]
teaching_assignment = source_tables["TeachingAssignment"]
assessment = source_tables["Assessment"]

fact_enrollment = (
    enrollments.alias("e")
    .join(
        section_context.alias("sc"),
        F.col("e.ClassSectionKey") == F.col("sc.ClassSectionKey"),
    )
    .select(
        F.col("e.EnrollmentKey").alias("EnrollmentKey"),
        F.col("e.StudentKey").alias("StudentKey"),
        F.col("e.ClassSectionKey").alias("ClassSectionKey"),
        F.col("sc.SchoolUnitKey").alias("SchoolUnitKey"),
        F.col("sc.CampusKey").alias("CampusKey"),
        F.col("sc.EducationStage").alias("EducationStage"),
        F.col("e.TrackKey").alias("TrackKey"),
        F.col("e.ProfileKey").alias("ProfileKey"),
        F.col("sc.AcademicYearKey").alias("AcademicYearKey"),
        F.col("sc.YearLevelKey").alias("YearLevelKey"),
    )
)

fact_subject_enrollment = (
    source_tables["EnrollmentSubject"].alias("es")
    .join(
        enrollments.alias("e"),
        F.col("es.EnrollmentKey") == F.col("e.EnrollmentKey"),
    )
    .join(
        teaching_assignment.alias("ta"),
        F.col("es.TeachingAssignmentKey") == F.col("ta.TeachingAssignmentKey"),
    )
    .join(subject.alias("s"), F.col("ta.SubjectKey") == F.col("s.SubjectKey"))
    .join(
        section_context.alias("sc"),
        F.col("e.ClassSectionKey") == F.col("sc.ClassSectionKey"),
    )
    .select(
        F.col("es.EnrollmentKey").alias("EnrollmentKey"),
        F.col("e.StudentKey").alias("StudentKey"),
        F.col("e.ClassSectionKey").alias("ClassSectionKey"),
        F.col("sc.SchoolUnitKey").alias("SchoolUnitKey"),
        F.col("sc.CampusKey").alias("CampusKey"),
        F.col("sc.EducationStage").alias("EducationStage"),
        F.col("e.TrackKey").alias("TrackKey"),
        F.col("sc.AcademicYearKey").alias("AcademicYearKey"),
        F.col("sc.YearLevelKey").alias("YearLevelKey"),
        F.col("s.SubjectKey").alias("SubjectKey"),
        F.col("s.DepartmentKey").alias("DepartmentKey"),
        F.col("es.TeachingAssignmentKey").alias("TeachingAssignmentKey"),
    )
)

fact_attendance = (
    attendance_context
    .select(
        F.col("e.EnrollmentKey").alias("EnrollmentKey"),
        F.col("e.StudentKey").alias("StudentKey"),
        F.col("e.ClassSectionKey").alias("ClassSectionKey"),
        F.col("sc.CampusKey").alias("CampusKey"),
        F.col("sc.EducationStage").alias("EducationStage"),
        F.col("sc.AcademicYearKey").alias("AcademicYearKey"),
        F.col("sc.YearLevelKey").alias("YearLevelKey"),
        F.col("e.TrackKey").alias("TrackKey"),
        F.col("a.DateKey").alias("DateKey"),
        F.col("a.CalendarDate").alias("CalendarDate"),
        F.col("a.AttendanceStatus").alias("AttendanceStatus"),
    )
)

fact_assessment_result = (
    results.alias("r")
    .join(
        assessment.alias("a"),
        (F.col("r.AssessmentKey") == F.col("a.AssessmentKey"))
        & (F.col("r.TeachingAssignmentKey") == F.col("a.TeachingAssignmentKey")),
    )
    .join(
        source_tables["EnrollmentSubject"].alias("es"),
        (F.col("r.EnrollmentKey") == F.col("es.EnrollmentKey"))
        & (F.col("r.TeachingAssignmentKey") == F.col("es.TeachingAssignmentKey")),
    )
    .join(
        teaching_assignment.alias("ta"),
        F.col("r.TeachingAssignmentKey") == F.col("ta.TeachingAssignmentKey"),
    )
    .join(subject.alias("s"), F.col("ta.SubjectKey") == F.col("s.SubjectKey"))
    .join(enrollments.alias("e"), F.col("r.EnrollmentKey") == F.col("e.EnrollmentKey"))
    .join(
        section_context.alias("sc"),
        F.col("e.ClassSectionKey") == F.col("sc.ClassSectionKey"),
    )
    .join(date_dimension.alias("d"), F.col("a.DateKey") == F.col("d.DateKey"))
    .where(F.col("d.CalendarDate") <= snapshot_date)
    .select(
        F.col("r.AssessmentKey").alias("AssessmentKey"),
        F.col("r.EnrollmentKey").alias("EnrollmentKey"),
        F.col("e.StudentKey").alias("StudentKey"),
        F.col("r.TeachingAssignmentKey").alias("TeachingAssignmentKey"),
        F.col("e.ClassSectionKey").alias("ClassSectionKey"),
        F.col("sc.SchoolUnitKey").alias("SchoolUnitKey"),
        F.col("sc.CampusKey").alias("CampusKey"),
        F.col("sc.EducationStage").alias("EducationStage"),
        F.col("sc.AcademicYearKey").alias("AcademicYearKey"),
        F.col("sc.YearLevelKey").alias("YearLevelKey"),
        F.col("e.TrackKey").alias("TrackKey"),
        F.col("s.SubjectKey").alias("SubjectKey"),
        F.col("s.DepartmentKey").alias("DepartmentKey"),
        F.col("a.DateKey").alias("DateKey"),
        F.col("d.CalendarDate").alias("CalendarDate"),
        F.col("a.AssessmentPeriod").alias("AssessmentPeriod"),
        F.col("a.AssessmentType").alias("AssessmentType"),
        F.col("r.Mark").alias("Mark"),
        F.col("r.QualitativeOutcome").alias("QualitativeOutcome"),
    )
)

silver_outputs = {
    "dim_campus": campus.select("CampusKey", "CampusName", "City", "HolidayRegion"),
    "dim_school_unit": school_unit.select(
        "SchoolUnitKey", "CampusKey", "SchoolUnitName", "EducationStage"
    ),
    "dim_academic_year": academic_year.select(
        "AcademicYearKey", "AcademicYearName", "FirstDate", "LastDate"
    ),
    "dim_year_level": year_level.select(
        "YearLevelKey", "EducationStage", "LevelNumber", "YearLevelName"
    ),
    "dim_programme_track": track.select("TrackKey", "TrackName", "DurationYears"),
    "dim_department": department.select("DepartmentKey", "DepartmentName"),
    "dim_subject": subject.select("SubjectKey", "SubjectName", "DepartmentKey"),
    "dim_date": date_dimension.select(
        "DateKey", "CalendarDate", "CalendarYear", "MonthNumber",
        "MonthName", "DayOfWeekName",
    ),
    "dim_class_section": section_context.select(
        "ClassSectionKey", "SchoolUnitKey", "CampusKey", "EducationStage",
        "AcademicYearKey", "YearLevelKey", "SectionCode",
    ),
    "dim_student": student.select("StudentKey"),
    "dim_teacher": teacher.select("TeacherKey", "SchoolUnitKey", "DepartmentKey"),
    "fact_enrollment": fact_enrollment,
    "fact_subject_enrollment": fact_subject_enrollment,
    "fact_attendance": fact_attendance,
    "fact_assessment_result": fact_assessment_result,
}

expected_output_counts = {
    "fact_enrollment": 5600,
    "fact_subject_enrollment": 43550,
    "fact_attendance": 315842,
    "fact_assessment_result": 87100,
}
for table_name, expected_count in expected_output_counts.items():
    actual_count = silver_outputs[table_name].count()
    require(
        actual_count == expected_count,
        f"{table_name} row count {actual_count} does not match {expected_count}.",
    )

distinct_subject_enrollments = fact_subject_enrollment.select(
    "EnrollmentKey", "SubjectKey"
).distinct().count()
require(
    distinct_subject_enrollments == 43550,
    "The snapshot must contain 43,550 distinct learner-subject enrollments.",
)

for table_name, frame in silver_outputs.items():
    write_silver(table_name, frame)

silver_manifest = spark.createDataFrame(
    [(
        batch_id,
        source_snapshot_date,
        scenario_version,
        "Validated",
        json.dumps(actual_counts, sort_keys=True),
        5600,
        43550,
        315842,
        87100,
    )],
    [
        "BatchId", "SourceSnapshotDate", "ScenarioVersion", "RunStatus",
        "SourceRowCountsJson", "EnrollmentRows", "SubjectEnrollmentRows",
        "ObservedAttendanceRows", "AssessmentResultRows",
    ],
)
(
    silver_manifest.write.format("delta")
    .mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(f"{silver_lakehouse_name}.dbo.silver_batch_manifest")
)

print(
    f"Validated batch {batch_id}: 5,600 enrollments, 43,550 subject enrollments, "
    "315,842 observed student-days, and 87,100 assessment results."
)
