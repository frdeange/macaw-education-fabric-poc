# Medallion architecture for agent-ready education data

This is the target architecture for [issue #7](https://github.com/frdeange/macaw-education-fabric-poc/issues/7).
The existing SQL database, its OneLake mirror, the initial semantic model,
the unshared Data Agents and the Foundry agent remain the current deployment.
The three schema-enabled Lakehouses are deployed but empty; their SQL endpoints
accepted administrator queries. Ingestion, the HorizonDB source and the
Gold-backed models described here have not yet been deployed or validated.
Restricted-user access to the Lakehouses and their endpoints is unverified.

## Data flow

```text
Fabric SQL Database --> native OneLake mirror ------+
                                                   |
Fabric HorizonDB ----> OneLake mirror -------------+--> Bronze --> Silver --> Gold
  (Azure PostgreSQL fallback if unavailable)       |                      /       \
                                                   |             Operations      Outcomes
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
| Fabric HorizonDB | A managed PostgreSQL **public preview** item containing synthetic rooms, capacities and closures. For a database with Federated Analytics enabled, eligible tables mirror asynchronously to OneLake. Use Azure Database for PostgreSQL Flexible Server only if HorizonDB is unavailable and its fallback prerequisites are satisfied. |
| Timetable CSV | Reproducibly generate fictional class, subject, teacher and room assignments. Deliver unchanged files to Bronze `Files/landing/timetable/<batch_id>/` and retain each original. |
| Dutch holiday reference | Preserve a versioned extract of the official regional dates, provenance and advisory status. Compare it with the existing fictional school calendar; do not assume that advisory dates are mandatory for every school. |

No separate scheduling application or DUO dataset is required. All pupil,
teacher, timetable and facilities data are synthetic. Government holiday dates
are public reference information, not actual observations from a school.

The SQL and HorizonDB mirrors are distinct from the Bronze Lakehouse. Verify
that a OneLake shortcut is supported for each actual mirror and the pipeline
identity before using it. Materialize selected data into Bronze Delta tables;
if a shortcut is unsupported, evaluate a documented route from the mirrored
analytical copy rather than silently reading the operational database. Monitor
each table's initial copy, later changes and reseeds. A mirror is a current
replica, not an immutable change history or a freshness guarantee.

For CSV deliveries, the first demo may upload files directly to the Lakehouse
`Files` area. Subsequent deliveries use a repeatable, authenticated upload.
Record the batch, source, timestamp and checksum; parse with an explicit
schema and quarantine invalid rows. Replaying a batch must not duplicate
records, and neither a malformed file nor an incomplete source snapshot may be
published as a successful refresh.

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

A parameterized pipeline runs validation and materialization in order. Record
batch lineage and freshness, make retries safe, surface failures, and prevent
an incomplete batch from replacing a validated Gold release. Retain the
current deployment as a rollback path until cutover is verified.

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
  The documented HorizonDB creation route is the portal; version schema and
  synthetic seed scripts in Git, and document creator-only manual steps unless
  a supported automation contract is verified.
- If HorizonDB is unavailable, the approved Azure PostgreSQL fallback requires
  a compatible General Purpose or Memory Optimized tier, network and
  replication prerequisites; Burstable is not supported for mirroring.

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
- [Lakehouse shortcuts and permissions](https://learn.microsoft.com/en-us/fabric/data-engineering/lakehouse-shortcuts)
- [Dutch school holidays 2026-2027](https://www.rijksoverheid.nl/themas/onderwijs/schoolvakanties/overzicht-schoolvakanties-per-schooljaar/overzicht-schoolvakanties-2026-2027)
