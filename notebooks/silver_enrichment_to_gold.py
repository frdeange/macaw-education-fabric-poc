# %% [markdown]
# # Silver to Gold: planned schedules and observed incidents
#
# These products are not a four-source consolidation: PostgreSQL rooms and
# planned closures remain pending. A planned slot is not an observed lesson.

# %% [parameters]
silver_lakehouse_name = "__SILVER_LAKEHOUSE_NAME__"
gold_lakehouse_name = "__GOLD_LAKEHOUSE_NAME__"

# %%
raise RuntimeError(
    "Draft notebook: verify and integrate the PostgreSQL rooms and closures mirror before execution."
)

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
    and source["PostgreSQLStatus"] == "Pending",
    "Gold enrichment requires the current validated SQL and enrichment batches.",
)


def write_manifest(status, totals):
    manifest = spark.createDataFrame(
        [(
            source["SourceSqlBatchId"], source["SourceSnapshotDate"],
            source["TimetableBatchId"], source["IncidentBatchId"],
            status, "Pending", json.dumps(totals, sort_keys=True),
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
for name, source_batch in (
    ("planned_timetable", source["TimetableBatchId"]),
    ("regional_holiday", source["TimetableBatchId"]),
    ("facility_incident", source["IncidentBatchId"]),
    ("facility_incident_event", source["IncidentBatchId"]),
):
    frame = spark.read.table(f"{silver_lakehouse_name}.dbo.{name}")
    lineage = frame.select("_batch_id", "_source_sql_batch_id").distinct().limit(2).collect()
    require(
        len(lineage) == 1
        and lineage[0]["_batch_id"] == source_batch
        and lineage[0]["_source_sql_batch_id"] == source["SourceSqlBatchId"],
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
)
gold_incidents = incidents.groupBy("campus_key", "incident_status", "category").agg(
    F.count("*").alias("observed_incident_count"),
)
outputs = {
    "gold_planned_timetable_by_campus_day": gold_schedule,
    "gold_facility_incidents_by_campus": gold_incidents,
}
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
}
require(
    totals == {
        "planned_weekly_assignment_count": 2485,
        "planned_subject_enrollment_slots": 43550,
        "observed_incident_count": 20,
    },
    f"Gold enrichment totals differ from the validated snapshot: {totals}.",
)
for name, frame in outputs.items():
    (
        frame.withColumn("_source_sql_batch_id", F.lit(source["SourceSqlBatchId"]))
        .withColumn("_source_snapshot_date", F.to_date(F.lit(source["SourceSnapshotDate"])))
        .write.format("delta").mode("overwrite").option("overwriteSchema", "true")
        .saveAsTable(f"{gold_lakehouse_name}.dbo.{name}")
    )
write_manifest("Validated", totals)
print("Validated planned timetable and observed-incident products; PostgreSQL remains pending.")
