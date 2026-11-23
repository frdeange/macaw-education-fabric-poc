# %% [markdown]
# # Silver to Gold: agent-ready education products
#
# Read only a validated Silver batch and materialize aggregate Delta products
# for school operations and learning outcomes. Gold contains no student or
# teacher names and does not infer lesson-level attendance.

# %% [parameters]
# Pipeline-overridable parameters.
silver_lakehouse_name = "__SILVER_LAKEHOUSE_NAME__"
gold_lakehouse_name = "__GOLD_LAKEHOUSE_NAME__"

# %%
import json
import re
from pyspark.sql import functions as F


def require(condition, message):
    if not condition:
        raise ValueError(message)


require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", silver_lakehouse_name) is not None,
        "Invalid Silver Lakehouse name.")
require(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", gold_lakehouse_name) is not None,
        "Invalid Gold Lakehouse name.")

manifest_rows = (
    spark.read.table(f"{silver_lakehouse_name}.dbo.silver_batch_manifest")
    .limit(2)
    .collect()
)
require(len(manifest_rows) == 1, "Silver must expose exactly one current batch manifest.")
manifest = manifest_rows[0]
require(manifest["RunStatus"] == "Validated",
        "Gold will not consume a Silver batch that has not passed validation.")
batch_id = manifest["BatchId"]
source_snapshot_date = manifest["SourceSnapshotDate"]
require(batch_id and source_snapshot_date, "Silver batch lineage is incomplete.")

silver_table_names = [
    "dim_campus",
    "dim_school_unit",
    "dim_academic_year",
    "dim_year_level",
    "dim_programme_track",
    "dim_department",
    "dim_subject",
    "dim_date",
    "dim_class_section",
    "fact_enrollment",
    "fact_subject_enrollment",
    "fact_attendance",
    "fact_assessment_result",
]
silver_tables = {}
for table_name in silver_table_names:
    frame = spark.read.table(f"{silver_lakehouse_name}.dbo.{table_name}")
    batch_ids = [row["_batch_id"] for row in frame.select("_batch_id").distinct().limit(2).collect()]
    require(batch_ids == [batch_id], f"{table_name} is not from the validated Silver batch.")
    silver_tables[table_name] = frame

# %%
enrollment = silver_tables["fact_enrollment"]
subject_enrollment = silver_tables["fact_subject_enrollment"]
attendance = silver_tables["fact_attendance"]
assessment_result = silver_tables["fact_assessment_result"]

gold_enrollment_by_year_level = (
    enrollment.groupBy(
        "campus_key", "education_stage", "academic_year_key",
        "year_level_key", "track_key",
    )
    .agg(
        F.countDistinct("student_key").alias("student_count"),
        F.countDistinct("enrollment_key").alias("enrollment_count"),
        F.countDistinct("class_section_key").alias("class_section_count"),
    )
)

gold_class_section_sizes = (
    enrollment.groupBy(
        "campus_key", "education_stage", "academic_year_key",
        "year_level_key", "class_section_key",
    )
    .agg(
        F.countDistinct("student_key").alias("student_count"),
        F.countDistinct("enrollment_key").alias("enrollment_count"),
    )
)

gold_subject_enrollment = (
    subject_enrollment.groupBy(
        "campus_key", "education_stage", "academic_year_key",
        "year_level_key", "track_key", "subject_key", "department_key",
    )
    .agg(
        F.countDistinct("student_key").alias("student_count"),
        F.countDistinct("class_section_key").alias("class_section_count"),
        F.countDistinct("teaching_assignment_key").alias("teaching_assignment_count"),
    )
)

gold_attendance_by_campus_day = (
    attendance.groupBy("campus_key", "date_key", "calendar_date")
    .agg(
        F.count("*").alias("observed_attendance_records"),
        F.sum(F.when(F.col("attendance_status") == "Present", 1).otherwise(0))
        .alias("present_count"),
        F.sum(F.when(F.col("attendance_status") == "Late", 1).otherwise(0))
        .alias("late_count"),
        F.sum(F.when(F.col("attendance_status") == "Authorized absence", 1).otherwise(0))
        .alias("authorized_absence_count"),
        F.sum(F.when(F.col("attendance_status") == "Unauthorized absence", 1).otherwise(0))
        .alias("unauthorized_absence_count"),
    )
    .withColumn(
        "attendance_rate_numerator",
        F.col("present_count") + F.col("late_count"),
    )
    .withColumn(
        "attendance_rate_denominator",
        F.col("observed_attendance_records"),
    )
    .withColumn(
        "attendance_rate",
        F.col("attendance_rate_numerator") / F.col("attendance_rate_denominator"),
    )
)

gold_assessment_results = (
    assessment_result.groupBy(
        "campus_key", "education_stage", "academic_year_key",
        "year_level_key", "track_key", "subject_key", "department_key",
        "assessment_period",
    )
    .agg(
        F.count("*").alias("assessment_result_count"),
        F.count("mark").alias("numeric_mark_count"),
        F.avg("mark").alias("average_mark"),
        F.sum(F.when(F.col("qualitative_outcome").isNotNull(), 1).otherwise(0))
        .alias("qualitative_outcome_count"),
        F.sum(F.when(F.col("qualitative_outcome") == "Emerging", 1).otherwise(0))
        .alias("emerging_count"),
        F.sum(F.when(F.col("qualitative_outcome") == "Developing", 1).otherwise(0))
        .alias("developing_count"),
        F.sum(F.when(F.col("qualitative_outcome") == "Secure", 1).otherwise(0))
        .alias("secure_count"),
    )
)

gold_outputs = {
    "gold_enrollment_by_year_level": gold_enrollment_by_year_level,
    "gold_class_section_sizes": gold_class_section_sizes,
    "gold_subject_enrollment": gold_subject_enrollment,
    "gold_attendance_by_campus_day": gold_attendance_by_campus_day,
    "gold_assessment_results": gold_assessment_results,
}

expected_totals = {
    "gold_enrollment_by_year_level": ("student_count", 5600),
    "gold_class_section_sizes": ("student_count", 5600),
    "gold_subject_enrollment": ("student_count", 43550),
    "gold_attendance_by_campus_day": ("observed_attendance_records", 315842),
    "gold_assessment_results": ("assessment_result_count", 87100),
}
actual_totals = {}
for table_name, (measure, expected_total) in expected_totals.items():
    actual_total = gold_outputs[table_name].agg(F.sum(measure).alias("total")).first()["total"]
    require(
        actual_total == expected_total,
        f"{table_name}.{measure} total {actual_total} does not match {expected_total}.",
    )
    actual_totals[table_name] = int(actual_total)

section_size_stats = gold_class_section_sizes.agg(
    F.count("*").alias("SectionCount"),
    F.min("student_count").alias("MinimumClassSize"),
    F.max("student_count").alias("MaximumClassSize"),
).first()
require(
    section_size_stats["SectionCount"] == 280
    and section_size_stats["MinimumClassSize"] == 20
    and section_size_stats["MaximumClassSize"] == 20,
    "Gold class-size output must contain 280 sections of 20 learners each.",
)

# A staging manifest makes partial writes fail closed for downstream consumers.
staging = spark.createDataFrame(
    [(batch_id, source_snapshot_date, "Staging", json.dumps(actual_totals, sort_keys=True))],
    ["BatchId", "SourceSnapshotDate", "RunStatus", "ProductTotalsJson"],
)
(
    staging.write.format("delta")
    .mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(f"{gold_lakehouse_name}.dbo.gold_batch_manifest")
)

for table_name in [
    "dim_campus",
    "dim_school_unit",
    "dim_academic_year",
    "dim_year_level",
    "dim_programme_track",
    "dim_department",
    "dim_subject",
    "dim_date",
    "dim_class_section",
]:
    (
        silver_tables[table_name].write.format("delta")
        .mode("overwrite")
        .option("overwriteSchema", "true")
        .saveAsTable(f"{gold_lakehouse_name}.dbo.{table_name}")
    )

for table_name, frame in gold_outputs.items():
    (
        frame.withColumn("_batch_id", F.lit(batch_id))
        .withColumn("_source_snapshot_date", F.to_date(F.lit(source_snapshot_date)))
        .write.format("delta")
        .mode("overwrite")
        .option("overwriteSchema", "true")
        .saveAsTable(f"{gold_lakehouse_name}.dbo.{table_name}")
    )

published = spark.createDataFrame(
    [(batch_id, source_snapshot_date, "Validated", json.dumps(actual_totals, sort_keys=True))],
    ["BatchId", "SourceSnapshotDate", "RunStatus", "ProductTotalsJson"],
)
(
    published.write.format("delta")
    .mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(f"{gold_lakehouse_name}.dbo.gold_batch_manifest")
)

print(
    f"Validated Gold batch {batch_id}: 5,600 enrollments, 43,550 subject enrollments, "
    "315,842 observed student-days, and 87,100 assessment results."
)
