# %% [markdown]
# # Bronze to Silver: planned timetables and facilities incidents
#
# Conform the landed CSV batch and the Cosmos mirror with the validated SQL
# snapshot. PostgreSQL room capacity and closures are not yet integrated.

# %% [parameters]
bronze_lakehouse_name = "__BRONZE_LAKEHOUSE_NAME__"
silver_lakehouse_name = "__SILVER_LAKEHOUSE_NAME__"
expected_snapshot_date = "2026-11-20"
timetable_batch_id = "timetable-2026-2027-v2"
incident_batch_id = "facilities-incidents-2026-2027-v1"

# %%
raise RuntimeError(
    "Draft notebook: verify and integrate the PostgreSQL rooms and closures mirror before execution."
)

# %%
import json
import re
from pyspark.sql import functions as F
from pyspark.sql import types as T
from pyspark.sql.window import Window


def require(condition, message):
    if not condition:
        raise ValueError(message)


def assert_unique(frame, columns, label):
    require(
        frame.groupBy(*columns).count().where(F.col("count") > 1).limit(1).count() == 0,
        f"{label} has duplicate keys: {columns}.",
    )


def assert_batch(frame, batch, label):
    values = [row["_batch_id"] for row in frame.select("_batch_id").distinct().limit(2).collect()]
    require(values == [batch], f"{label} does not belong to the validated SQL batch.")


for name in (bronze_lakehouse_name, silver_lakehouse_name):
    require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name), "Invalid Lakehouse name.")
require(timetable_batch_id == "timetable-2026-2027-v2", "Unexpected timetable batch.")
require(incident_batch_id == "facilities-incidents-2026-2027-v1", "Unexpected incident batch.")

sql_manifest_rows = spark.read.table(
    f"{silver_lakehouse_name}.dbo.silver_batch_manifest"
).limit(2).collect()
require(len(sql_manifest_rows) == 1, "The SQL Silver manifest is missing or ambiguous.")
sql_manifest = sql_manifest_rows[0]
require(
    sql_manifest["RunStatus"] == "Validated"
    and str(sql_manifest["SourceSnapshotDate"]) == expected_snapshot_date,
    "The SQL Silver snapshot is not validated for the expected date.",
)
sql_batch_id = sql_manifest["BatchId"]
manifest_table = f"{silver_lakehouse_name}.dbo.silver_enrichment_manifest"


def write_manifest(status, totals):
    manifest = spark.createDataFrame(
        [(
            sql_batch_id, expected_snapshot_date, timetable_batch_id,
            incident_batch_id, status, "Pending", json.dumps(totals, sort_keys=True),
        )],
        [
            "SourceSqlBatchId", "SourceSnapshotDate", "TimetableBatchId",
            "IncidentBatchId", "RunStatus", "PostgreSQLStatus", "RowCountsJson",
        ],
    )
    (
        manifest.write.format("delta").mode("overwrite")
        .option("overwriteSchema", "true").saveAsTable(manifest_table)
    )


write_manifest("Staging", {})

manifest_path = f"Files/landing/timetable/{timetable_batch_id}/manifest_2026_2027.json"
manifest_text = "\n".join(row["value"] for row in spark.read.text(manifest_path).collect())
source_manifest = json.loads(manifest_text)
require(
    source_manifest["batchId"] == timetable_batch_id
    and source_manifest["observationDate"] == expected_snapshot_date,
    "The landed timetable manifest does not match the SQL snapshot.",
)


def read_landed_csv(key, expected_count, columns):
    source = source_manifest["files"][key]
    path = source["oneLakePath"]
    require(path.startswith("Files/landing/"), f"Unexpected path for {key}.")
    require(source["rowCount"] == expected_count, f"Unexpected manifest count for {key}.")
    file_rows = (
        spark.read.format("binaryFile").load(path)
        .select(F.sha2("content", 256).alias("sha256")).limit(2).collect()
    )
    require(
        len(file_rows) == 1 and file_rows[0]["sha256"] == source["sha256"],
        f"The landed {key} file does not match its SHA-256 manifest.",
    )
    schema = T.StructType([T.StructField(name, T.StringType(), True) for name in columns])
    frame = (
        spark.read.format("csv").schema(schema).option("header", "true")
        .option("enforceSchema", "false").option("mode", "FAILFAST").load(path)
    )
    require(frame.count() == expected_count, f"Unexpected row count for {key}.")
    return frame, path


timetable_columns = [
    "ScheduleId", "TeachingAssignmentKey", "ClassSectionKey", "CampusKey", "SubjectKey",
    "TeacherKey", "RoomCode", "DayOfWeek", "PeriodNumber", "StartTime", "EndTime",
    "EffectiveStartDate", "EffectiveEndDate", "RecurrencePattern", "ScheduleStatus",
]
holiday_columns = [
    "Region", "SourceRegion", "HolidayName", "StartDate", "EndDate",
    "DateStatus", "IsAdvisory", "SchoolYear", "SourceUrl", "RetrievedDate",
]
timetable_raw, timetable_path = read_landed_csv("timetable", 2485, timetable_columns)
holiday_raw, holiday_path = read_landed_csv("regionalHolidays", 21, holiday_columns)
require(
    timetable_raw.where(
        F.array_contains(F.array(*[F.col(name).isNull() for name in timetable_columns]), True)
    ).limit(1).count() == 0,
    "The timetable contains missing required values.",
)
require(
    holiday_raw.where(
        F.array_contains(F.array(*[F.col(name).isNull() for name in holiday_columns]), True)
    ).limit(1).count() == 0,
    "The holiday reference contains missing required values.",
)

timetable = timetable_raw.select(
    F.col("ScheduleId").alias("schedule_id"),
    F.col("TeachingAssignmentKey").cast("int").alias("teaching_assignment_key"),
    F.col("ClassSectionKey").cast("int").alias("class_section_key"),
    F.col("CampusKey").cast("int").alias("campus_key"),
    F.col("SubjectKey").cast("int").alias("subject_key"),
    F.col("TeacherKey").cast("int").alias("teacher_key"),
    F.col("RoomCode").alias("room_code"),
    F.col("DayOfWeek").alias("day_of_week"),
    F.col("PeriodNumber").cast("int").alias("period_number"),
    F.col("StartTime").alias("start_time"),
    F.col("EndTime").alias("end_time"),
    F.to_date("EffectiveStartDate").alias("effective_start_date"),
    F.to_date("EffectiveEndDate").alias("effective_end_date"),
    F.col("RecurrencePattern").alias("recurrence_pattern"),
    F.col("ScheduleStatus").alias("schedule_status"),
)
invalid_schedule = timetable.where(
    F.col("teaching_assignment_key").isNull()
    | F.col("class_section_key").isNull()
    | F.col("campus_key").isNull()
    | F.col("subject_key").isNull()
    | F.col("teacher_key").isNull()
    | F.col("period_number").isNull()
    | ~F.col("period_number").between(1, 8)
    | ~F.col("day_of_week").isin("Monday", "Tuesday", "Wednesday", "Thursday", "Friday")
    | ~F.col("start_time").rlike(r"^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$")
    | ~F.col("end_time").rlike(r"^(0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$")
    | (F.col("start_time") >= F.col("end_time"))
    | F.col("effective_start_date").isNull()
    | F.col("effective_end_date").isNull()
    | (F.col("effective_start_date") != F.lit("2026-08-17").cast("date"))
    | (F.col("effective_end_date") != F.lit("2027-07-23").cast("date"))
    | (F.col("recurrence_pattern") != "EveryInstructionalWeek")
    | (F.col("schedule_status") != "Planned")
)
require(invalid_schedule.limit(1).count() == 0, "The timetable has invalid schedule values.")
assert_unique(timetable, ["schedule_id"], "Timetable")
assert_unique(timetable, ["teaching_assignment_key"], "Timetable")
for key in ("class_section_key", "teacher_key", "room_code"):
    assert_unique(timetable, [key, "day_of_week", "period_number"], f"Timetable {key}")

assignments = (
    spark.read.format("delta").load("Tables/sql/TeachingAssignment")
    .select(
        F.col("TeachingAssignmentKey").alias("teaching_assignment_key"),
        F.col("ClassSectionKey").alias("source_class_section_key"),
        F.col("SubjectKey").alias("source_subject_key"),
        F.col("TeacherKey").alias("source_teacher_key"),
    )
)
sections = spark.read.table(f"{silver_lakehouse_name}.dbo.dim_class_section")
subjects = spark.read.table(f"{silver_lakehouse_name}.dbo.dim_subject")
enrollments = spark.read.table(f"{silver_lakehouse_name}.dbo.fact_subject_enrollment")
for name, frame in (
    ("dim_class_section", sections), ("dim_subject", subjects),
    ("fact_subject_enrollment", enrollments),
):
    assert_batch(frame, sql_batch_id, name)
section_context = sections.select("class_section_key", "campus_key", "education_stage")
subject_context = subjects.select("subject_key", "department_key")
assignment_students = enrollments.groupBy("teaching_assignment_key").agg(
    F.countDistinct("student_key").alias("planned_subject_student_count")
)
matched = timetable.join(assignments, "teaching_assignment_key", "left")
require(
    matched.where(
        F.col("source_class_section_key").isNull()
        | (F.col("class_section_key") != F.col("source_class_section_key"))
        | (F.col("subject_key") != F.col("source_subject_key"))
        | (F.col("teacher_key") != F.col("source_teacher_key"))
    ).limit(1).count() == 0,
    "A timetable row does not match the mirrored SQL teaching assignment.",
)
planned_schedule = (
    matched.drop("source_class_section_key", "source_subject_key", "source_teacher_key")
    .join(section_context, ["class_section_key", "campus_key"], "left")
    .join(subject_context, "subject_key", "left")
    .join(assignment_students, "teaching_assignment_key", "left")
)
require(
    planned_schedule.count() == 2485
    and planned_schedule.where(
        F.col("education_stage").isNull()
        | F.col("department_key").isNull()
        | F.col("planned_subject_student_count").isNull()
    ).limit(1).count() == 0,
    "Timetable rows do not match validated sections, subjects, or subject enrollments.",
)
require(
    planned_schedule.agg(F.sum("planned_subject_student_count").alias("total")).first()["total"] == 43550,
    "The timetable assignment enrollment total does not match the SQL snapshot.",
)

holidays = holiday_raw.select(
    F.col("Region").alias("region"),
    F.col("SourceRegion").alias("source_region"),
    F.col("HolidayName").alias("holiday_name"),
    F.to_date("StartDate").alias("start_date"),
    F.to_date("EndDate").alias("end_date"),
    F.col("DateStatus").alias("date_status"),
    F.when(F.col("IsAdvisory") == "true", F.lit(True))
    .when(F.col("IsAdvisory") == "false", F.lit(False)).alias("is_advisory"),
    F.col("SchoolYear").alias("school_year"),
    F.col("SourceUrl").alias("source_url"),
    F.to_date("RetrievedDate").alias("retrieved_date"),
)
require(
    holidays.where(
        ~F.col("region").isin("North", "Central", "South")
        | F.col("start_date").isNull()
        | F.col("end_date").isNull()
        | (F.col("start_date") > F.col("end_date"))
        | F.col("is_advisory").isNull()
        | (F.col("is_advisory") & (F.col("date_status") != "Advisory"))
        | (~F.col("is_advisory") & (F.col("date_status") != "Published"))
    ).limit(1).count() == 0,
    "The holiday reference contains invalid dates, regions, or advisory flags.",
)
assert_unique(holidays, ["region", "holiday_name", "school_year"], "Holiday reference")

# %%
event_schema = T.ArrayType(T.StructType([
    T.StructField("eventType", T.StringType(), True),
    T.StructField("occurredOn", T.StringType(), True),
]))
raw_incidents = spark.read.format("delta").load("Tables/CosmosDB/FacilityIncidents")
require(raw_incidents.count() == 20, "The Cosmos mirror must contain 20 incident documents.")
incidents = raw_incidents.select(
    F.col("id").alias("incident_id"),
    F.col("campusKey").alias("_raw_campus_key"),
    F.col("campusKey").cast("int").alias("campus_key"),
    F.col("roomCode").alias("room_code"),
    F.col("category").alias("category"),
    F.col("status").alias("incident_status"),
    F.to_date("reportedOn").alias("reported_on"),
    F.to_date("lastUpdatedOn").alias("last_updated_on"),
    F.to_date("observedThrough").alias("observed_through"),
    F.col("sourceVersion").alias("source_version"),
    F.from_json("events", event_schema).alias("events"),
)
require(
    incidents.where(
        F.col("incident_id").isNull()
        | F.col("_raw_campus_key").isNull()
        | (F.col("_raw_campus_key") != F.col("campus_key"))
        | ~F.col("campus_key").between(1, 5)
        | F.col("room_code").isNull()
        | F.col("category").isNull()
        | ~F.col("category").isin("Heating", "Lighting", "Ventilation", "Furniture")
        | F.col("incident_status").isNull()
        | ~F.col("incident_status").isin("Open", "Resolved")
        | F.col("reported_on").isNull()
        | F.col("last_updated_on").isNull()
        | F.col("observed_through").isNull()
        | (F.col("observed_through") != F.lit(expected_snapshot_date).cast("date"))
        | F.col("source_version").isNull()
        | (F.col("source_version") != incident_batch_id)
        | F.col("events").isNull()
        | (F.size("events") < 1)
    ).limit(1).count() == 0,
    "Cosmos incidents have invalid identifiers, values, or observation dates.",
)
assert_unique(incidents, ["incident_id"], "Cosmos incidents")
incident_events = incidents.select(
    "incident_id", F.posexplode("events").alias("event_index", "event")
).select(
    "incident_id", "event_index",
    F.col("event.eventType").alias("event_type"),
    F.to_date("event.occurredOn").alias("occurred_on"),
)
require(
    incident_events.where(
        F.col("occurred_on").isNull()
        | (F.col("occurred_on") > F.lit(expected_snapshot_date).cast("date"))
        | F.col("event_type").isNull()
        | ~F.col("event_type").isin("Reported", "Inspected", "Resolved")
    ).limit(1).count() == 0,
    "An incident history has an invalid or future event.",
)
assert_unique(incident_events, ["incident_id", "event_index"], "Incident history")
ordered_events = incident_events.withColumn(
    "_previous_date",
    F.lag("occurred_on").over(Window.partitionBy("incident_id").orderBy("event_index")),
)
require(
    ordered_events.where(
        ((F.col("event_index") == 0) & (F.col("event_type") != "Reported"))
        | (F.col("occurred_on") < F.col("_previous_date"))
    ).limit(1).count() == 0,
    "Incident history must start with a report and remain in chronological order.",
)
last_events = (
    incident_events.withColumn(
        "_rank",
        F.row_number().over(Window.partitionBy("incident_id").orderBy(F.desc("event_index"))),
    )
    .where(F.col("_rank") == 1)
    .select("incident_id", F.col("event_type").alias("last_event_type"))
)
event_bounds = incident_events.groupBy("incident_id").agg(
    F.min("occurred_on").alias("first_event_date"),
    F.max("occurred_on").alias("last_event_date"),
    F.sum(F.when(F.col("event_type") == "Resolved", 1).otherwise(0)).alias("resolved_events"),
)
incidents = incidents.join(event_bounds, "incident_id").join(last_events, "incident_id")
require(
    incidents.where(
        (F.col("reported_on") != F.col("first_event_date"))
        | (F.col("last_updated_on") != F.col("last_event_date"))
        | ((F.col("incident_status") == "Open") & (F.col("resolved_events") != 0))
        | (
            (F.col("incident_status") == "Resolved")
            & ((F.col("resolved_events") != 1) | (F.col("last_event_type") != "Resolved"))
        )
    ).limit(1).count() == 0,
    "Incident status and history are inconsistent.",
)
status_counts = incidents.groupBy("campus_key", "incident_status").count()
require(
    status_counts.count() == 10 and status_counts.where(F.col("count") != 2).count() == 0,
    "Each campus must have two open and two resolved incidents.",
)
require(incident_events.count() == 40, "The incident snapshot must contain 40 history events.")


def write_silver(name, frame, source_batch, source_path):
    (
        frame.withColumn("_batch_id", F.lit(source_batch))
        .withColumn("_source_sql_batch_id", F.lit(sql_batch_id))
        .withColumn("_source_path", F.lit(source_path))
        .withColumn("_ingested_at", F.current_timestamp())
        .write.format("delta").mode("overwrite").option("overwriteSchema", "true")
        .saveAsTable(f"{silver_lakehouse_name}.dbo.{name}")
    )


write_silver("planned_timetable", planned_schedule, timetable_batch_id, timetable_path)
write_silver("regional_holiday", holidays, timetable_batch_id, holiday_path)
write_silver(
    "facility_incident",
    incidents.drop(
        "_raw_campus_key", "events", "first_event_date", "last_event_date",
        "resolved_events", "last_event_type",
    ),
    incident_batch_id,
    "Tables/CosmosDB/FacilityIncidents",
)
write_silver(
    "facility_incident_event", incident_events, incident_batch_id,
    "Tables/CosmosDB/FacilityIncidents",
)
write_manifest("Validated", {
    "planned_timetable": 2485, "regional_holiday": 21,
    "facility_incident": 20, "facility_incident_event": 40,
})
print("Validated SQL, CSV, and Cosmos enrichment; PostgreSQL facilities remain pending.")
