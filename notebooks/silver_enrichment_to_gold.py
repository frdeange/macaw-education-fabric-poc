# %% [markdown]
# # Silver to Gold: planned schedules, closures, and observed incidents
#
# A planned slot or closure is not an observed lesson or incident.

# %% [parameters]
silver_lakehouse_name = "__SILVER_LAKEHOUSE_NAME__"
gold_lakehouse_name = "__GOLD_LAKEHOUSE_NAME__"

# %%
import json
import re
from pyspark.sql import functions as F


def require(condition, message):
    if not condition:
        raise ValueError(message)


for name in (silver_lakehouse_name, gold_lakehouse_name):
    require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name), "Invalid Lakehouse name.")
sql_rows = spark.read.table(f"{silver_lakehouse_name}.dbo.silver_batch_manifest").limit(2).collect()
source_rows = spark.read.table(f"{silver_lakehouse_name}.dbo.silver_enrichment_manifest").limit(2).collect()
require(len(sql_rows) == 1 and len(source_rows) == 1, "Silver manifests are missing or ambiguous.")
sql_manifest, source = sql_rows[0], source_rows[0]
require(
    sql_manifest["RunStatus"] == "Validated"
    and source["RunStatus"] == "Validated"
    and source["SourceSqlBatchId"] == sql_manifest["BatchId"]
    and source["SourceSnapshotDate"] == str(sql_manifest["SourceSnapshotDate"])
    and source["PostgreSQLStatus"] == "Validated",
    "Gold enrichment requires the current validated SQL and enrichment batches.",
)


def write_manifest(status, totals):
    manifest = spark.createDataFrame(
        [(
            source["SourceSqlBatchId"], source["SourceSnapshotDate"],
            source["TimetableBatchId"], source["IncidentBatchId"],
            status, source["PostgreSQLStatus"], json.dumps(totals, sort_keys=True),
        )],
        [
            "SourceSqlBatchId", "SourceSnapshotDate", "TimetableBatchId",
            "IncidentBatchId", "RunStatus", "PostgreSQLStatus", "ProductTotalsJson",
        ],
    )
    (
        manifest.write.format("delta").mode("overwrite").option("overwriteSchema", "true")
        .saveAsTable(f"{gold_lakehouse_name}.dbo.gold_enrichment_manifest")
    )


write_manifest("Staging", {})
tables = {}
source_counts = json.loads(source["RowCountsJson"])
for name, source_batch in (
    ("planned_timetable", source["TimetableBatchId"]),
    ("regional_holiday", source["TimetableBatchId"]),
    ("holiday_calendar_variance", source["TimetableBatchId"]),
    ("facility_incident", source["IncidentBatchId"]),
    ("facility_incident_event", source["IncidentBatchId"]),
    ("facility_room", source["TimetableBatchId"]),
    ("facility_closure", source["TimetableBatchId"]),
    ("planned_room_closure_impact", source["TimetableBatchId"]),
):
    frame = spark.read.table(f"{silver_lakehouse_name}.dbo.{name}")
    lineage = frame.select("_batch_id", "_source_sql_batch_id").distinct().limit(2).collect()
    require(
        frame.count() == source_counts[name]
        and (
            (not lineage and source_counts[name] == 0)
            or (
                len(lineage) == 1
                and lineage[0]["_batch_id"] == source_batch
                and lineage[0]["_source_sql_batch_id"] == source["SourceSqlBatchId"]
            )
        ),
        f"{name} does not match the validated source batches.",
    )
    tables[name] = frame

schedule = tables["planned_timetable"]
incidents = tables["facility_incident"]
gold_schedule = schedule.groupBy("campus_key", "education_stage", "department_key", "day_of_week").agg(
    F.count("*").alias("planned_weekly_assignment_count"),
    F.countDistinct("class_section_key").alias("planned_class_section_count"),
    F.countDistinct("teacher_key").alias("planned_teacher_count"),
    F.sum("planned_subject_student_count").alias("planned_subject_enrollment_slots"),
    F.sum(F.when(F.col("is_capacity_exceeded"), 1).otherwise(0)).alias("planned_capacity_exceedance_count"),
)
gold_incidents = incidents.groupBy("campus_key", "incident_status", "category").agg(
    F.count("*").alias("observed_incident_count"),
)
gold_closure_impacts = tables["planned_room_closure_impact"].groupBy(
    "campus_key", "department_key", "education_stage", "closure_date"
).agg(
    F.count("*").alias("planned_affected_assignment_count"),
    F.countDistinct("closure_key").alias("planned_closure_count"),
)
outputs = {
    "gold_planned_timetable_by_campus_day": gold_schedule,
    "gold_facility_incidents_by_campus": gold_incidents,
    "gold_planned_closure_impacts": gold_closure_impacts,
}
detail_outputs = {
    "gold_room": tables["facility_room"].select(
        "room_key", "campus_key", "room_code", "room_type", "capacity",
    ),
    "gold_planned_assignment": schedule.select(
        "schedule_id", "teaching_assignment_key", "campus_key", "class_section_key",
        "subject_key", "department_key", "teacher_key", "room_key", "education_stage",
        "day_of_week", "period_number", "start_time", "end_time",
        "effective_start_date", "effective_end_date", "planned_subject_student_count",
        "capacity", "is_capacity_exceeded",
    ),
    "gold_facility_incident": incidents.select(
        "incident_id", "campus_key", "room_code", "category", "incident_status",
        "reported_on", "last_updated_on", "observed_through",
    ),
    "gold_planned_room_closure": tables["facility_closure"].select(
        "closure_key", "campus_key", "room_code", "closure_date",
        "closure_reason", "status", "is_instruction_day",
    ),
    "gold_planned_closure_assignment": tables["planned_room_closure_impact"].select(
        "closure_key", "schedule_id", "closure_date", "campus_key", "department_key",
        "room_key", "teaching_assignment_key", "class_section_key", "subject_key",
        "education_stage", "period_number", "planned_subject_student_count",
    ),
}
for name, source_name in (
    ("gold_room", "facility_room"),
    ("gold_planned_assignment", "planned_timetable"),
    ("gold_facility_incident", "facility_incident"),
    ("gold_planned_room_closure", "facility_closure"),
    ("gold_planned_closure_assignment", "planned_room_closure_impact"),
):
    require(detail_outputs[name].count() == source_counts[source_name],
            f"{name} does not match the validated Silver row count.")
totals = {
    "planned_weekly_assignment_count": gold_schedule.agg(
        F.sum("planned_weekly_assignment_count").alias("value")
    ).first()["value"],
    "planned_subject_enrollment_slots": gold_schedule.agg(
        F.sum("planned_subject_enrollment_slots").alias("value")
    ).first()["value"],
    "observed_incident_count": gold_incidents.agg(
        F.sum("observed_incident_count").alias("value")
    ).first()["value"],
    "planned_capacity_exceedance_count": gold_schedule.agg(
        F.sum("planned_capacity_exceedance_count").alias("value")
    ).first()["value"],
    "planned_affected_assignment_count": tables["planned_room_closure_impact"].count(),
}
require(
    totals == {
        "planned_weekly_assignment_count": 2485,
        "planned_subject_enrollment_slots": 43550,
        "observed_incident_count": 20,
        "planned_capacity_exceedance_count": source_counts["planned_capacity_exceedances"],
        "planned_affected_assignment_count": source_counts["planned_room_closure_impact"],
    },
    f"Gold enrichment totals differ from the validated snapshot: {totals}.",
)
for name, frame in {**outputs, **detail_outputs}.items():
    (
        frame.withColumn("_source_sql_batch_id", F.lit(source["SourceSqlBatchId"]))
        .withColumn("_source_snapshot_date", F.to_date(F.lit(source["SourceSnapshotDate"])))
        .write.format("delta").mode("overwrite").option("overwriteSchema", "true")
        .saveAsTable(f"{gold_lakehouse_name}.dbo.{name}")
    )
write_manifest("Validated", totals)
print("Validated planned timetable and closure impacts and observed-incident products.")
