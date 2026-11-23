# Medallion architecture for agent-ready education data

This is the target architecture for [issue #7](https://github.com/frdeange/macaw-education-fabric-poc/issues/7).
The existing SQL database, its OneLake mirror, the initial semantic model,
the unshared Data Agents and the Foundry agent remain the current deployment.
The three schema-enabled Lakehouses are deployed and their SQL endpoints are
available. Bronze contains 20 individual shortcuts to the SQL mirror, verified
with the workspace administrator. The first SQL-mirror-only Silver/Gold
pipeline run completed after an attendance-count contract correction; its
products and validated manifests were read back through the SQL analytics
endpoints. Bronze now also contains the immutable raw timetable/holiday source
batch `timetable-2026-2027-v2`; its three uploaded files were read back and
matched their local SHA-256 digests. Cosmos incident documents, their mirror
and the Bronze shortcut have also been verified. An interrupted enrichment
run left partial Silver tables with a `Staging` manifest, not validated
products; no enrichment Gold notebook ran. PostgreSQL facilities have not
been seeded or mirrored, and Gold-backed models have not been deployed.
Restricted-user access to the Lakehouses and their endpoints is unverified.

## Data flow

```text
Fabric SQL Database --> native OneLake mirror ------+
                                                   |
PostgreSQL facilities --> OneLake mirror (pending)-+--> Bronze --> Silver --> Gold
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
| Timetable CSV | `scripts/generate_timetable.py` reproducibly creates 2,485 fictional weekly class, subject, teacher and room assignments. The immutable `v2` timetable and manifest are landed at `Files/landing/timetable/timetable-2026-2027-v2/`. The source assignment reconstruction matched the live SQL analytics endpoint: 2,485 expected and actual assignments, zero mismatches across keys, sections, subjects, or teachers. The generated room codes still await validation against HorizonDB. |
| Dutch holiday reference | The 21-row extract preserves the 18 regional 2026-2027 holiday ranges plus the three 2025-2026 summer ranges needed to validate the 2026 start of the snapshot. It includes official source URLs, school year, retrieval date, and advisory status. The SQL school calendar was not changed. |

The approved Azure PostgreSQL fallback was provisioned before HorizonDB
availability was confirmed. The server is now Ready in Sweden Central on
General Purpose D2ads v5 with 32 GiB of storage, Entra-only authentication,
and public network access disabled. It incurs compute and storage charges.
The prepared source schema enforces closure-to-room campus consistency, and
its validator checks the source keys and foreign key. These have only been
tested locally.
The empty `macaw_facilities` database, a project-tenant Entra administrator
and a system-assigned managed identity exist; no Fabric permissions were
granted to the identity. Connectivity, schema, seed and mirror remain
unverified. The supported `fabric-mirroring start` command completed and
readback showed mirroring enabled with `wal_level=logical`, but the reported
extension allowlist and preload values do not show `azure_cdc`; its
registration and readiness require verification. A VNet data gateway consumes
4 CUs per active member and may contend with the shared F4 capacity; obtain
approval before activating it. A Fabric managed private endpoint supports Spark
connectivity but is not documented as a mirroring gateway. The documented
NotebookUtils token audiences do not include PostgreSQL, so a supported private
Entra-authenticated seeding route is still unverified.

The current identity can see one VNet outside the project resource group,
with no Power Platform-delegated subnet; its ownership and suitability are
unverified. It can see no private endpoint targeting this PostgreSQL server,
and local DNS returned no RFC 1918 IPv4 address. These point-in-time checks
are permission-limited and do not establish that other paths do not exist.
Do not modify the existing VNet without approval.

The source loader now includes the extension's pre-creation
`azure_cdc.check_prerequisites()` check in addition to the role and table
checks. The PostgreSQL shortcut path is prepared locally with an explicit
two-table contract and a mirror preflight, but no mirror or shortcut exists.
The preflight requires manually observed table paths and checks the VNet
connection, definition, paginated replication status and Delta-log access. It
does not prove source-to-mirror equality, current data, pipeline access, or
security.
[`POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED`](../fabric/POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED)
prevents the included script from creating PostgreSQL shortcuts until the
independent security and validation gates are met; it is not an access control.
All new mirror checks have only been exercised against simulated responses.

No separate scheduling application or DUO dataset is required. All pupil,
teacher, timetable and facilities data are synthetic. Government holiday dates
are public reference information, not actual observations from a school.

The source files and checksums are recorded in
[`data/sources/timetable/manifest_2026_2027.json`](../data/sources/timetable/manifest_2026_2027.json).
The uploader stores and verifies the raw timetable, holiday extract and
manifest without overwriting existing batch paths. An earlier immutable `v1`
upload with 18 holiday rows remains in Bronze; use only the `v2` paths.
Facilities seed CSVs are not uploaded as an alternate source of truth: they
are inputs for the pending HorizonDB seed.

The SQL and HorizonDB mirrors are distinct from the Bronze Lakehouse. Verify
that a OneLake shortcut is supported for each actual mirror and the pipeline
identity before using it. Materialize selected data into Bronze Delta tables;
if a shortcut is unsupported, evaluate a documented route from the mirrored
analytical copy rather than silently reading the operational database. Monitor
each table's initial copy, later changes and reseeds. A mirror is a current
replica, not an immutable change history or a freshness guarantee.

The SQL mirror's 20 operational tables are enumerated, with their source keys,
in [`sql-bronze-tables.json`](../fabric/sql-bronze-tables.json). Individual
shortcuts under Bronze `Files/sql_mirror/` point only to those tables; the
`Analytics*` snapshots and `SecurityAccessGrant` are excluded. The deployment
script verifies the actual shortcut targets and access to their Delta-log
directories, and does not overwrite existing paths. These checks do not prove
that a separately configured pipeline identity can use the shortcuts, nor
that the mirror is complete or current. No access grants were made.

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
are not validated products and must not be consumed. No enrichment Gold
notebook ran. The deployed draft notebooks now fail before writing until the
PostgreSQL mirror is verified and integrated. The complete transform must
validate mirrored foreign keys and compare the calendar without silently
rewriting it.

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
Unknown rooms, capacities or enrollments are reported as unknown, not as
conflict-free. Facility capacity checks use the enrollment relevant to each
scheduled section and subject.

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
  allowlisted Delta shortcuts from Bronze `Files/sql_mirror/`. It checks the
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
included in this first validated slice. The incomplete enrichment staging
tables are separate and must not be consumed as products.

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
its four activities, ordered dependency, and both pipeline parameters. The
corrected pipeline run completed and its Silver/Gold outputs and manifests
were validated through the SQL analytics endpoints. Definition deployment
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
  documents Basic authentication for Script activity; the private-only
  fallback has password authentication disabled. The
  [mirroring tutorial](https://learn.microsoft.com/en-us/fabric/mirroring/azure-database-postgresql-tutorial)
  separately documents an organizational account and a VNet gateway. Fabric
  managed private endpoints support PostgreSQL for Spark workloads, but a
  private Entra-authenticated seed route and managed-endpoint use for
  mirroring have not been verified. Do not treat these as interchangeable.
- `scripts/load_postgres_facilities.py` is a local, tenant-checked Entra
  loader with transactional creation and full snapshot comparison. It requires
  preexisting private DNS/connectivity and TLS certificate verification; it
  neither creates that route nor configures a mirror. Its use against the
  Azure server remains unverified.

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
