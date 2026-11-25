# Medallion architecture for agent-ready education data

This is the target architecture for [issue #7](https://github.com/frdeange/macaw-education-fabric-poc/issues/7).
The existing SQL database and its OneLake mirror remain deployed. The owner
deleted the initial semantic model and Data Agents; the existing Foundry version
still references those deleted agents.
The three schema-enabled Lakehouses are deployed and their SQL endpoints are
available. The owner created schema shortcuts for the SQL, Cosmos and
PostgreSQL mirrors in Bronze. The first SQL-mirror-only Silver/Gold pipeline
run completed after an attendance-count contract correction; its products and
validated manifests were read back through the SQL analytics endpoints before
the shortcut migration. The SQL-only pipeline was rerun successfully after the
migration. Bronze also contains the immutable raw timetable/holiday batch
`timetable-2026-2027-v2`, whose three files matched their local SHA-256
digests. Later enrichment runs replaced an earlier incomplete staging batch.
The four-stage pipeline was deployed, read back and run; all four manifests
and Silver/Gold totals were validated through their SQL endpoints. Two
Gold-backed models and agents have since been created without sharing.
Detailed Gold products and revised models have been deployed and checked as
an administrator. Agent acceptance and restricted-user access remain open.

## Data flow

```text
Fabric SQL Database --> native OneLake mirror ------+
                                                   |
PostgreSQL facilities --> OneLake mirror ----------+--> Bronze --> Silver --> Gold
  (HorizonDB preferred; Azure fallback in use)      |                      /       \
Fabric Cosmos DB ----> OneLake mirror -------------+             Operations      Outcomes
Synthetic timetable CSV + official holiday dates --+             model           model
                                                                      \           /
                                                               Two Fabric Data Agents
                                                                        |
                                                                 Foundry / Fabric IQ
```

The three Lakehouses are separate Fabric items in one development workspace
on the existing capacity. They use OneLake; they are not three separate Azure
Storage accounts. Validate that the selected workspace is appropriate for
isolated development before provisioning. Separate Lakehouses in one workspace
do not by themselves enforce a security boundary.

## Sources and Bronze

| Source | Landing and purpose |
| --- | --- |
| Fabric SQL Database | Reuse its existing asynchronous OneLake mirror. Ingest allowlisted operational tables, including enrollment and subject enrollment, rather than querying the transactional endpoint or relying on the old analytical snapshots. |
| Fabric HorizonDB | A managed PostgreSQL **public preview** item containing synthetic rooms, capacities and closures. The 300-room, 10-planned-closure schema and seed are prepared under `postgres/`, but HorizonDB has not been created or seeded. For a database with Federated Analytics enabled, eligible tables mirror asynchronously to OneLake. Use Azure Database for PostgreSQL Flexible Server only if HorizonDB is unavailable and its fallback prerequisites are satisfied. |
| Fabric Cosmos DB | A synthetic incident container with 20 documents and 40 historical events. Every mirrored document was compared with the reproducible seed; a Bronze shortcut points to the mirror. Room identifiers do not establish that an incident caused a planned closure. |
| Timetable CSV | `scripts/generate_timetable.py` reproducibly creates 2,485 fictional weekly class, subject, teacher and room assignments. The immutable `v2` timetable and manifest are landed at `Files/landing/timetable/timetable-2026-2027-v2/`. The source assignment reconstruction matched the live SQL analytics endpoint: 2,485 expected and actual assignments, zero mismatches across keys, sections, subjects, or teachers. The enrichment run matched all room codes against the PostgreSQL mirror. |
| Dutch holiday reference | The 21-row extract preserves the 18 regional 2026-2027 holiday ranges plus the three 2025-2026 summer ranges needed to validate the 2026 start of the snapshot. It includes official source URLs, school year, retrieval date, and advisory status. The SQL school calendar was not changed. |

The approved Azure PostgreSQL fallback was provisioned before HorizonDB
availability was confirmed. The server is now Ready in Sweden Central on
General Purpose D2ads v5 with 32 GiB of storage, Entra-only authentication,
and public network access enabled. It incurs compute and storage charges.
The prepared source schema enforces closure-to-room campus consistency, and
its validator checks the source keys and foreign key. These have only been
tested against Azure PostgreSQL with 300 rooms and 10 planned closures.
The `macaw_facilities` database, a project-tenant Entra administrator
and a system-assigned managed identity exist. The mirroring tutorial says
creation grants that identity read/write on the mirror; its effective
permissions have not been independently audited. The administrator's CDC
prerequisites and both tables' eligibility passed. An Azure-services firewall
rule permits connection attempts from all Azure subscriptions; Entra
authentication remains required.
The temporary client IP rule used for seeding was removed. An encrypted
organizational-account cloud connection and a facilities mirror are deployed.
Consumer security remains unverified.

The current identity can see one VNet outside the project resource group,
with no Power Platform-delegated subnet; its ownership and suitability are
unverified. It could see no private endpoint targeting this PostgreSQL server.
These point-in-time checks are permission-limited.
Do not modify the existing VNet without approval.

The source loader now includes the extension's pre-creation
`azure_cdc.check_prerequisites()` check in addition to the role and table
checks. The PostgreSQL schema shortcut was created by the owner; the local
mirror preflight retains an explicit two-table contract.
Both selected tables report `Replicating`, and the 300 room and 10 closure
rows in the SQL analytics endpoint match the previously validated source seed.
Their Delta logs were observed under `Tables/_public/`. The preflight accepts
the encrypted cloud connection or VNet connection, and checks the definition,
paginated replication status and manually observed Delta-log paths. It
does not prove source-to-mirror equality, current data, pipeline access, or
security.
[`POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED`](../fabric/POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED)
is retained until the independent security and validation gates are met; it
is not an access control and did not prevent the owner-created shortcut.
The included script no longer creates legacy `Files` shortcuts.
The live preflight fails closed because the returned definition omits
`mountedTables`; the portal showed the two-table selection with future tables
disabled. The [definition documentation](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/mirrored-database-definition)
says omitting `mountedTables` selects all tables, including future tables.
The effective selection remains unconfirmed. The definition check must not be
bypassed without another reliable verification of persistent selection. The
successful preflight tests use simulated responses.

No separate scheduling application or DUO dataset is required. All pupil,
teacher, timetable and facilities data are synthetic. Government holiday dates
are public reference information, not actual observations from a school.

The source files and checksums are recorded in
[`data/sources/timetable/manifest_2026_2027.json`](../data/sources/timetable/manifest_2026_2027.json).
The uploader stores and verifies the raw timetable, holiday extract and
manifest without overwriting existing batch paths. An earlier immutable `v1`
upload with 18 holiday rows remains in Bronze; use only the `v2` paths.
Facilities seed CSVs are not uploaded as an alternate source of truth: they
were inputs for the Azure PostgreSQL seed and remain available for HorizonDB.

The mirrors are distinct from the Bronze Lakehouse. Read the selected tables
through their schema shortcuts and materialize validated Silver and Gold
products; no SQL-mirror Bronze copy has been made. Validate the actual
pipeline identity and monitor each table's initial copy, later changes and
reseeds. A mirror is a current replica, not an immutable change history or a
freshness guarantee.

The SQL mirror's 20 operational tables are enumerated, with their source keys,
in [`sql-bronze-tables.json`](../fabric/sql-bronze-tables.json). The notebook
reads only those tables, but the schema shortcut itself also exposes the
`Analytics*` snapshots and `SecurityAccessGrant`. The table contract is a
processing allowlist, not an access control.

### Bronze schema shortcuts

The owner created schema shortcuts for the SQL, Cosmos and PostgreSQL
mirrors and removed the old SQL and Cosmos shortcuts under `Files`. The raw
CSV files remain in place.
[Lakehouse schema shortcuts](https://learn.microsoft.com/en-us/fabric/data-engineering/lakehouse-schemas#bring-multiple-tables-with-schema-shortcut)
reference all tables in the selected source schema; the documented
[OneLake shortcut API](https://learn.microsoft.com/en-us/rest/api/fabric/core/onelake-shortcuts/create-shortcut)
does not specify a table allowlist for a schema target.

| Bronze schema | Mirror schema | Cataloged tables |
| --- | --- | --- |
| `sql` | Fabric SQL `dbo` | 27: 20 reviewed operational tables, six `Analytics*` snapshots and `SecurityAccessGrant` |
| `CosmosDB` | Cosmos `MacawFacilitiesIncidents` | One incident table |
| `PostGre` | PostgreSQL `_public` | Two facilities tables |

Fabric REST confirmed the three shortcut targets; OneLake's table catalog
listed the counts above. An administrator used Spark to read 5,600 students,
2,485 teaching assignments, 20 incidents, 300 rooms and 10 closures through
the new paths. SQL and Cosmos verify-only scripts also checked the target
and Delta-log paths. A live query of the Bronze SQL analytics endpoint
returned all three schemas: `sql` (27 tables), `CosmosDB` (one table) and
`PostGre` (two tables). These checks do not prove mirror freshness, pipeline
identity access, or restricted-user isolation.
The [metadata sync status API](https://learn.microsoft.com/en-us/rest/api/fabric/sqlendpoint/items/get-sql-endpoint-metadata-sync-migration-status)
reported legacy `V1`, with no migration in progress or recorded migration
attempt. The schemas and tables were nevertheless returned by the SQL query.

The SQL and enrichment notebook definitions now use the schema paths.
The CSV and manifest files passed read-only checksum verification. Future
source tables may also appear through a schema shortcut; PostgreSQL's
persistent source-table selection remains unconfirmed.

A point-in-time workspace role inventory and the Bronze Lakehouse and SQL
endpoint item-access inventories each listed only the signed-in administrator.
Bronze and the PostgreSQL mirror each had only a `DefaultReader` OneLake role
with all-path access for `ReadAll` holders. These observations do not prove
restricted-user isolation or the SQL endpoint's access mode. Separately
configure and test the required controls before exposing a new path; retain
the PostgreSQL deployment block until its documented gates pass.

An administrator compared counts for all 20 operational source tables with
the SQL analytics endpoint; they matched, including 5,600 students, 240
teachers, 280 sections, 336,000 student-day records, 87,100 assessment results
and 43,550 subject-enrollment records. The source change-feed procedure
reported state `Active` for all 20, and the declared key columns matched the
source primary keys. These are point-in-time checks, not a cross-table
transaction, proof of row-by-row equality, or a freshness SLA.
The independently captured counts are retained in
[`sql-bronze-baseline.json`](../fabric/sql-bronze-baseline.json), separate
from future Bronze output; they apply only to the recorded synthetic snapshot.
Initial-copy and per-table mirror monitoring, source changes and the actual
pipeline identity still need validation before a batch is treated as current.

The raw `v2` files are already landed at their manifest paths, and a
read-after-write check verified each SHA-256. Re-run
[`deploy-timetable-sources.ps1`](../scripts/deploy-timetable-sources.ps1) with
`-VerifyOnly` to check the immutable files without writing. Replaying the same
content is a no-op; different content at an existing batch path is rejected.
An enrichment run was started before the PostgreSQL prerequisite and then
cancelled. Although the job reports `Completed`, direct Delta readback found
only 2,485 timetable, 21 holiday and 20 incident rows, with the manifest still
`Staging`; the incident-event table was absent. These partial Silver tables
were not validated products. Subsequent enrichment notebook runs replaced the
staging batch and validated the PostgreSQL room and closure relationships,
the planned timetable, the holiday calendar comparison and Cosmos incidents.
The SQL calendar was not rewritten.

The live SQL calendar comparison found 20 dates that remain instructional
during the optional May 1-9, 2027 holiday extension: four dates at each of the
five campuses (May 3-5 and May 7; May 6 is an existing synthetic closure).
All are advisory dates. The preceding 2025-2026 summer holidays end on August
16 (North), August 30 (Central), and August 23 (South), matching the SQL
calendar's August 17, August 31, and August 24 starts. Preserve the 20-day
advisory variance as a documented school-calendar choice; do not change the
synthetic SQL calendar without approval.

## Silver and Gold

Silver validates keys, types, year-level and track eligibility, and joins the
fictional campus, class, subject, calendar, timetable and facility records.
Schedule revisions and cancellations must be resolved deterministically.
The current snapshot validation rejects unknown rooms, capacities or
enrollments rather than treating them as conflict-free. Facility capacity
checks use the enrollment relevant to each scheduled section and subject.

Gold publishes curated Delta facts and conformed dimensions for two domains:

- **School Operations:** distinct students and enrollments, student-day
  attendance, calendars, planned lessons and validated room conflicts.
- **Learning Outcomes:** assessment counts, qualitative primary outcomes and
  numeric secondary marks by campus, year, track, subject and department.

Keep the baseline snapshot independently verifiable: 5,600 students, 240
teachers, 280 classes, 336,000 student-day attendance records and 87,100
assessment results. The existing subject-enrollment baseline includes 960
students taking Dutch at each campus. Compare like-for-like snapshots and
report a calendar discrepancy rather than silently changing the baseline.

Timetable records describe *planned* lessons. They do not prove that a lesson
occurred or that a student attended it. Attendance is recorded by student-day:
its rate is `(Present + Late) / all observed attendance records`. Do not
produce lesson- or subject-level attendance from a timetable join. Dates after
the observation snapshot are schedules, not observed facts.

The `Macaw Education Medallion` DataPipeline definition is deployed. It runs
Bronze-to-Silver before Silver-to-Gold, passes the snapshot date and batch ID
as pipeline parameters, and retries each notebook once. Its first run failed
twice in Bronze-to-Silver because the notebook compared total observed
attendance records with the Present-or-Late numerator: 315,842 instead of
336,000. The source SQL query confirmed 336,000 instructional student-day
records through the snapshot date, of which 315,842 are Present or Late. The
Silver and Gold count contracts now use the 336,000 record total. A subsequent
pipeline run completed, and both SQL analytics endpoints confirmed the
materialized outputs and `Validated` manifests. The Gold endpoint metadata was
refreshed before its readback. The notebook retry and explicit failure paths
were exercised by the initial failed run. No schedule or trigger is
configured. No email or Teams connection or destination was specified, so the
pipeline does not send an external failure notification. Restricted-user
access remains unverified.

### First SQL-mirror transformation slice

The versioned notebook sources in [`notebooks/`](../notebooks/) define a
first vertical slice for the current SQL-mirror snapshot only:

- [`bronze_to_silver.py`](../notebooks/bronze_to_silver.py) reads the 20
  reviewed Delta tables through Bronze `Tables/sql/`. It checks the
  reviewed per-table row-count and primary-key contracts, core foreign keys,
  class sizes, school-unit/year-level consistency, VMBO/HAVO/VWO duration and
  eligibility, observed instructional-day attendance, and assessment result
  shape. It excludes attendance after the `2026-11-20` observation cutoff.
- Silver writes conformed dimensions and enrollment, subject-enrollment,
  student-day attendance, and assessment-result facts. Student and teacher
  names are deliberately omitted; their source and mirror access remains
  unverified.
- [`silver_to_gold.py`](../notebooks/silver_to_gold.py) requires a validated
  Silver batch and produces enrollment-by-year-level, class-section sizes,
  subject enrollment, campus-day attendance, and assessment-outcome aggregates.
  Class sizes are grouped by section, not track, because sections are shared
  across applicable secondary tracks.

Gold grains retain campus, education stage, academic year, year level, track,
subject, department, date, and assessment period where relevant. Subject and
department learner counts overlap and must not be added as if they were
disjoint populations. Attendance remains student-day data; the only supported
rate is `(Present + Late) / all observed attendance records`. Assessment
averages use numeric marks only; qualitative primary outcomes are counted
separately. No planned timetable, lesson attendance, or facilities data is
included in this first SQL-only slice; enrichment products are separate.

The aggregate-only products discard student, assessment, schedule and incident
identifiers needed for valid distinct counts and richer cross-source questions.
The revised design retains separate detailed Gold facts and a distinct
campus/student/department bridge alongside the existing aggregates. The bridge
supports selecting student-day attendance for learners taking a department's
subjects; it does not create subject- or lesson-level attendance. Department
membership overlaps, so department subtotals are not additive. These new
products are not security controls and must remain unshared until tested.

The detailed products have these intended grains:

| Product | One row represents | Source |
| --- | --- | --- |
| Enrollment detail | One learner enrollment in one class section | SQL enrollment |
| Subject enrollment detail | One enrolled learner taking one subject | SQL teaching assignment and subject enrollment |
| Student department bridge | One enrolled learner associated with one department at a campus | Distinct subject-enrollment departments |
| Attendance detail | One observed learner-day | SQL attendance and school calendar |
| Assessment result detail | One learner's result for one assessment | SQL assessment and result |
| Room | One room at one campus | PostgreSQL |
| Planned assignment | One recurring weekly teaching assignment | Timetable CSV, SQL and PostgreSQL |
| Planned room closure | One planned room closure on a date | PostgreSQL and SQL school calendar |
| Planned closure assignment | One scheduled assignment overlapping one planned closure | Timetable, PostgreSQL and school calendar |
| Facility incident | One observed incident through the snapshot date | Cosmos DB |

These are curated, conformed projections of validated Silver facts rather than
raw copies of Bronze. No names are included. Both models now use detailed
facts, conformed dimensions and distinct-count measures; the operations model
uses subject enrollment to select students for department attendance. The
separate student-department bridge is retained in Gold but is not a model
security control. Existing aggregates remain optional products, not sources
for summing overlapping student or class counts.

Both Gold notebook jobs completed, with validated manifests. Administrator SQL
readback found 5,600 enrollments, 43,550 subject enrollments, 31,450 distinct
student-department associations, 336,000 student-days, 87,100 results, 300
rooms, 2,485 planned assignments, 20 incidents, 10 closures and 17 planned
overlaps. Selected columns matched Silver in Gold-to-Silver `EXCEPT` checks;
these checks do not prove full row equality or freshness.

Both revised Direct Lake models refreshed. Administrator DAX checks matched
the totals and the Science and Technology selection of 4,250 students,
255,000 student-days and 239,700 Present-or-Late records. A subject filter
returned blank for student-day attendance; Dutch enrollment at Amsterdam
returned 960. The outcomes model matched SQL totals and selected subject
breakdowns. These are not restricted-user tests.

### Learning Outcomes model corrections

The Gold notebook generates `dim_learning_outcomes_date` from the Silver
calendar bounds, extending them to full calendar years. It checks that Silver
dates match the generated calendar and every assessment date has a matching
key. The deployed snapshot has 730 unique dates from 2026-01-01 through
2027-12-31; the Operations model still uses the original calendar. Extra
calendar dates do not create observed assessments.

The Outcomes Date table is marked as Time, with its date column as the key and
an explicit date format. Six other dimension keys and the City data category
were checked. Whole-number measures use `#,0`. The hidden `Mark` column is
required by Secondary Average Mark, which intentionally keeps two decimals
rather than following the analyzer's whole-number warning. The analyzer has
not been rerun.

After refresh, administrator queries returned 730 calendar dates, 87,100
assessment results, 38,400 qualitative outcomes and an average mark of 6.75
when formatted. The `Calendar Dates` measure counts dates including days
without assessments. An Outcomes agent test returned the correct 17,420
results for 2026-09-11 and 730 when explicitly asked to use that measure.
However, a general distinct-date question still returned 731. A separate DAX
`VALUES` count includes a blank member, but the agent's generated query was
not captured and the cause of its answer is unconfirmed. Review the model's
Prep data for AI configuration and retest; the explicit measure alone is not
a guarantee of correct natural-language answers.

Both published agents remain unshared. MCP smoke tests returned 960 Dutch
students at each campus and 38,400 qualitative outcomes. The operations
agent initially misrepresented overall attendance as Dutch lesson attendance.
After its instructions were clarified, one retest correctly declined that
question, but a separate department student-day question incorrectly claimed
the data was unavailable. Published agent element descriptions still
contained old aggregate-only descriptions; these were corrected and verified
after republication, but the department question was still incorrectly
rejected. A Power BI schema response initially continued to show old aggregate
metadata after the model update. A later schema read returned the detailed
operations tables and measures; the cause of the earlier response is unknown.
In subsequent administrator MCP tests, two phrasings for Science and
Technology students returned the expected 255,000 observed student-days, and
a Dutch lesson attendance question was correctly declined. These are isolated
examples, not proof of general reliability or security. Do not connect the
agents to Foundry until representative testing and the relevant security
gates pass. Prep data for AI configuration and restricted-user security remain
unverified.

Snapshot-specific count checks and asynchronous source mirrors are not a
general freshness guarantee.

### Four-source enrichment

The Silver enrichment validates the landed files and snapshot lineage,
PostgreSQL room and closure keys and campus relationships, room capacity,
recurring timetable joins, calendar dates and incident history. Its validated
manifest and SQL endpoint readback contain 2,485 planned assignments, 21
holiday rows, 300 rooms, 10 planned closures, 20 observed incidents and 40
incident events. There are 17 planned closure/assignment overlaps and zero
planned capacity exceedances. The 20 holiday-calendar variances are all in the
advisory May extension. Gold aggregates 2,485 planned assignments, 43,550
planned subject enrollment slots, 17 affected assignment/closure pairs and 20
observed incidents. A closure can appear in more than one department; distinct
closure counts across departments must not be added. Shared room identifiers
do not establish that an incident caused a closure.

After the four-stage pipeline run, bidirectional SQL `EXCEPT` comparisons
found no differences between the Bronze PostgreSQL mirror and Silver room and
closure rows. An independent SQL reconstruction matched all planned
closure/assignment impact keys in both directions. These are point-in-time
comparisons, not a continuous replication guarantee.

These are administrator checks against the selected synthetic snapshot, not
proof of mirror freshness, a consistent cross-source transaction or effective
restricted-user permissions. The PostgreSQL definition's future-table
selection remains unconfirmed. Keep all Lakehouse and endpoint paths unshared
until cross-surface security and bypass tests pass.

The notebooks write batch lineage and a one-row manifest. The Gold manifest's
`Validated` status is a downstream processing gate, **not an access control**;
the Lakehouse tables and their SQL endpoints remain unverified for restricted
users and must not be shared. The current static row-count contract is tied to
the reviewed snapshot and must be deliberately revised for a different source
snapshot. The completed run was validated through the SQL analytics endpoints:
Silver contains 5,600 enrollment, 43,550 subject-enrollment, 336,000
student-day attendance and 87,100 assessment-result rows. Gold aggregate
measures total 5,600 enrollment learners, 5,600 class-size learners, 43,550
subject enrollments, 336,000 attendance records and 87,100 assessment
results. The attendance numerator remains 315,842 Present-or-Late records;
its denominator is 336,000 observed records. These administrator checks do
not establish restricted-user security or row-level equality with the source.

[`notebook_authoring.py`](../scripts/notebook_authoring.py) builds notebook
definitions with discovered workspace and default-Lakehouse bindings.
[`deploy-medallion-notebooks.ps1`](../scripts/deploy-medallion-notebooks.ps1)
deployed both definitions successfully and does not run Spark or grant access.
[`medallion-pipeline-content.json`](../fabric/medallion-pipeline-content.json)
defines the ordered activities and their failure paths;
[`deploy-medallion-pipeline.ps1`](../scripts/deploy-medallion-pipeline.ps1)
deployed the `Macaw Education Medallion` item. A definition readback confirmed
four sequential notebook activities, four failure activities, and both
pipeline parameters. A full pipeline run completed all four notebook
activities, and its Silver/Gold outputs and four manifests were validated
through the SQL analytics endpoints. Definition deployment
does not verify mirror freshness, external failure alerts, restricted-user
access, or cross-Lakehouse data permissions.

## Semantic models and agents

Build two focused, Gold-backed star-schema semantic models, with Direct Lake
as the preferred storage mode subject to environment and security validation.
Use explicit measures, correct grains and denominators, descriptive English
business names and useful Dutch education terms. Counts across subjects and
departments can overlap; distinct students must not be added across them.
Unsupported subject-filtered attendance should return blank rather than an
unfiltered result.

Review model metadata against the
[Data Agent semantic-model guidance](https://learn.microsoft.com/en-us/fabric/data-science/semantic-model-best-practices).
An authorized owner configures reviewed AI instructions, synonyms, AI schema
and verified answers in Power BI **Prep data for AI**; preserve existing
artifacts. Data Agent instructions are not passed to the semantic model's DAX
generator and are not security controls.

Test each model against independent SQL or controlled fixture results before
publishing its corresponding Data Agent. Test both MCP endpoints and the
delegated Foundry-to-Fabric IQ flow for routing, correct figures, unsupported
questions and restricted access. Do not expose student or teacher names
through consumer surfaces until their independent security gates pass. Names
already exist in the SQL source and mirrored paths, whose effective access is
not yet verified.

## Security and preview gates

- Access is granted to specific campus/department pairs, not the cross-product
  of separate lists. For enrollment and student-day attendance, show only
  learners with a subject in an authorized department at an authorized campus.
- A room, closure or scheduled-lesson result must be scoped through authorized
  campus/department lesson facts; do not expose an unfiltered facilities
  directory as a shortcut around the pair policy.
- Test authorized and denied pairs, overlapping departments, no-grant users
  and direct-access bypasses as non-administrators. SQL, HorizonDB, each
  mirrored endpoint, OneLake, every Lakehouse, each model, each Data Agent and
  Foundry require separately verified controls.
- Keep consumer access away from unprotected source, mirror and Lakehouse
  paths. Validate a least-privilege fixed identity for model data access where
  supported; do not assume semantic-model RLS protects OneLake or GraphQL.
- HorizonDB's current preview allows only its creator to connect to the
  operational PostgreSQL endpoint. The selected creator is the account used
  to administer the workspace. Other users, service principals and managed
  identities cannot connect; this does not establish access to, or security
  for, its analytical mirror.
- Confirm preview eligibility, capacity, region, networking, costs, supported
  table types and mirror health. Do not change tenant settings or bypass policy.
  The current HorizonDB onboarding procedure uses the portal. A separate
  `PostgreSQLDatabase` REST reference exists, but its applicability to
  HorizonDB is unconfirmed; a successful empty list response does not prove
  creation eligibility. No HorizonDB creation request was submitted.
  Version schema and synthetic seed scripts in Git, and document creator-only
  manual steps unless a supported automation contract is verified.
- If HorizonDB is unavailable, the approved Azure PostgreSQL fallback requires
  a compatible General Purpose or Memory Optimized tier, network and
  replication prerequisites; Burstable is not supported for mirroring.
- The [Azure PostgreSQL pipeline connector](https://learn.microsoft.com/en-us/fabric/data-factory/connector-azure-database-for-postgresql-overview)
  documents Basic authentication for Script activity; the
  fallback has password authentication disabled. The
  [mirroring tutorial](https://learn.microsoft.com/en-us/fabric/mirroring/azure-database-postgresql-tutorial)
  separately documents an organizational account and a VNet gateway. Fabric
  managed private endpoints support PostgreSQL for Spark workloads, but a
  managed-endpoint use for mirroring has not been verified.
- `scripts/load_postgres_facilities.py` is a local, tenant-checked Entra
  loader with transactional creation and full snapshot comparison. It requires
  TLS certificate verification and, with `--allow-public`, a public IPv4
  route. It loaded and verified the Azure source but does not configure a mirror.

The staged `SecurityAccessGrant` records are configuration, not enforcement.
The existing Data Agents remain unshared; Foundry project access has not been
comprehensively audited. GraphQL remains a separate read-only milestone in
[issue #4](https://github.com/frdeange/macaw-education-fabric-poc/issues/4).
The names and cross-surface security work remain tracked in
[issue #2](https://github.com/frdeange/macaw-education-fabric-poc/issues/2)
and [issue #1](https://github.com/frdeange/macaw-education-fabric-poc/issues/1).

## References

- [Fabric SQL Database mirroring](https://learn.microsoft.com/en-us/fabric/database/sql/mirroring-overview)
- [Fabric HorizonDB overview](https://learn.microsoft.com/en-us/fabric/database/horizondb/overview)
- [HorizonDB mirroring](https://learn.microsoft.com/en-us/fabric/database/horizondb/mirroring-overview)
- [HorizonDB preview limitations](https://learn.microsoft.com/en-us/fabric/database/horizondb/limitations)
- [HorizonDB REST API guidance](https://learn.microsoft.com/en-us/fabric/database/horizondb/deploy-rest-api)
- [Fabric PostgreSQL database REST API](https://learn.microsoft.com/en-us/rest/api/fabric/postgresqldatabase/items/create-postgre-sql-database)
- [Lakehouse shortcuts and permissions](https://learn.microsoft.com/en-us/fabric/data-engineering/lakehouse-shortcuts)
- [Dutch school holidays 2026-2027](https://www.rijksoverheid.nl/themas/onderwijs/schoolvakanties/overzicht-schoolvakanties-per-schooljaar/overzicht-schoolvakanties-2026-2027)
- [Dutch school holidays 2025-2026](https://www.government.nl/themes/education/school-holidays/overview-of-school-holiday-dates-per-academic-year/school-holiday-dates-2025-2026)
- [SQL assignment validation](../sql/validate-timetable-source.sql)
- [School-calendar comparison](../sql/validate-calendar-reference.sql)
