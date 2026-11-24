# Macaw education: Fabric and Foundry proof of concept

This project models a fictional Dutch primary and secondary education scenario
using Microsoft Fabric and Microsoft Foundry. All educational records and
person names are synthetic; names can coincide with real names and are not
identifiers. The scenario is illustrative, not a complete representation of
Dutch curricula or regulations.

> **Not ready for external sharing.** Campus- and department-level security
> has not been validated with restricted users. SQL, OneLake, the SQL analytics
> endpoint, the semantic model, Data Agents, and Foundry require separate
> permission checks. Do not expose names or other records to consumers until
> the relevant controls and bypass tests pass.

## Current deployed architecture

```text
Synthetic SQL seed
        |
        v
Fabric SQL Database -- asynchronous mirroring --> OneLake
                                                    |  \
                                                    |   --> SQL analytics endpoint
                                                    |        \
                                                    |         --> GraphQL API (planned)
                                                    v
                                          Direct Lake semantic model
                                            /                 \
                                           v                   v
                                School Operations      Learning Outcomes
                                  Data Agent              Data Agent
                                           \                   /
                                            v                 v
                                              Foundry agent
                                                Fabric IQ
```

The published Data Agent MCP endpoints provide conversational access. The
proposed GraphQL API is **not deployed**. The intended external consumers are
users in the same Microsoft Entra tenant, using delegated identities.

## Target medallion architecture

The approved design consolidates the existing SQL mirror, synthetic timetable
files, a PostgreSQL facilities source and synthetic Cosmos DB incidents through
separate Bronze, Silver and Gold Lakehouses. Two Gold-backed semantic models
will serve the Data Agents and Foundry. Fabric HorizonDB is the preferred
PostgreSQL source; it is a public preview. The owner created Bronze schema
shortcuts `sql`, `CosmosDB` and `PostGre` to the three mirrors; the raw CSV
files remain in `Files`. OneLake's table catalog lists 27, 1 and 2 tables in
those schemas respectively. Administrator Spark reads returned 5,600 SQL
students, 2,485 teaching assignments, 20 Cosmos incidents, 300 PostgreSQL
rooms and 10 closures. A live Bronze SQL analytics endpoint query returned all
three schemas: `sql` (27 tables), `CosmosDB` (one table) and `PostGre` (two
tables).

The SQL-mirror slice was rerun successfully after the schema-shortcut
migration; its Silver and Gold manifests and totals were checked through the
SQL analytics endpoints. Separate enrichment notebook runs have also
validated the four sources in Silver and Gold. They produced 2,485 planned
weekly assignments, 300 rooms, 10 planned closures, 20 observed incidents,
and 17 planned assignment/closure overlaps, with no capacity exceedances.
The 20 instructional dates within the advisory May holiday extension are
recorded without changing the school calendar. These overlaps are plans, not
observed lessons or incidents.

The four-stage `Macaw Education Medallion` pipeline definition has been
deployed and read back. It has no schedule or external failure-notification
connection. Validation is under an administrator identity and is not an
access control.
See the [medallion design](./docs/medallion-architecture.md) for source,
security and validation requirements.

The SQL schema shortcut includes six `Analytics*` snapshots and
`SecurityAccessGrant` in addition to the 20 operational tables used by the
notebook. The processing allowlist does **not** restrict access to those
additional tables or future tables. Restricted-user security remains
unverified; do not share the Lakehouse or its endpoints.

## Scenario

- Five fictional campuses, each with a primary and a secondary school unit.
- Eight primary groups and six possible secondary years; VMBO, HAVO, and VWO
  have four-, five-, and six-year programme lengths respectively. MBO and
  higher education are out of scope.
- Four class sections per campus and year level, with 20 distinct students in
  each section: 280 sections and 5,600 students.
- Synthetic teachers, subjects, teaching assignments, enrollments, attendance,
  assessments, and results. Subjects vary by stage, year, and track.
- A 2026-2027 calendar with regional holiday assumptions. The deployed
  observation snapshot is 20 November 2026; later dates are schedules, not
  observed facts. Schools can deviate from advisory holiday dates.
- Primary assessments are qualitative; simulated secondary marks use part of
  the Dutch 1-10 scale. The project does not model complete examination rules.

Students and teachers have separate, reproducibly generated first and last
names, including Unicode and compound surnames. Their artificial codes and keys
remain the identifiers. No real contact details or official pupil identifiers
are generated.

Attendance rate is `(present + late) / all observed attendance records`.
Attendance represents student-days, not attendance in individual lessons.
Students may take multiple subjects and belong to multiple departments, so
counts across subjects or departments can overlap.

## Verified status

| Component | Status |
| --- | --- |
| Fabric SQL Database | Deployed and validated: 5,600 students, 240 teachers, 280 sections, 336,000 attendance records, and 87,100 assessment results. |
| Synthetic names | Populated and validated in SQL. Student, teacher, and analytical learner counts and keyed name digests match the SQL analytics endpoint, including Unicode. |
| Mirroring and analytics | Operational and analytical tables are mirrored. The 43,550 subject-enrollment rows and the other analytical tables are point-in-time snapshots, not automatically refreshed from later operational changes. |
| Semantic model | Direct Lake model deployed and checked against SQL using an administrator identity. Its row-level security is **not validated**. Name fields are intentionally not in the published model. |
| Data Agents | Both agents are published but unshared. Administrator smoke tests returned 960 Dutch students per campus and 87,100 assessment results; individual-subject attendance was correctly declined. These tests do not establish general reliability or restricted-user isolation. |
| Foundry | A prompt agent with two delegated Fabric IQ connections was deployed and smoke-tested as an administrator. Version 1 predates the subject-enrollment instruction update; restricted-user access is unverified. |
| Medallion architecture | Three schema-enabled Lakehouses and the owner-created SQL, Cosmos and PostgreSQL Bronze schema shortcuts exist. The SQL pipeline was rerun after the shortcut migration, and separate four-source enrichment runs produced validated Silver and Gold manifests. The four-stage pipeline definition was deployed and read back. Restricted-user security is unverified. |
| Cosmos DB incidents | The synthetic container holds 20 incidents and 40 history events. All documents were compared with the OneLake mirror; an administrator Spark read through the Bronze schema shortcut returned 20 incidents. Restricted-user access remains unverified. |
| PostgreSQL facilities | The fallback server contains 300 synthetic rooms and 10 planned closures. Its Fabric mirror reports both tables replicating, and its SQL endpoint rows match the validated seed. Administrator Spark reads through the Bronze schema shortcut returned 300 and 10 rows. Public access is enabled with an Azure-services firewall rule, Entra authentication and passwords disabled. Persistent table selection and restricted-user security remain unverified. The server incurs compute and storage costs. |
| GraphQL | Planned only; no API, generated schema, or security validation has been completed. |
| Evaluation | Generated questions and a custom evaluator are unreviewed drafts. No batch evaluation or remote evaluation suite has been verified. |

The School Operations agent uses a Microsoft **preview** runtime for this PoC,
as accepted by the project owner. Preview features can change and are not
generally available. Validate capacity, tenant settings, permissions, regional
processing boundaries, networking, and costs in the target environment.

The source SQL database and its mirrored OneLake and SQL analytics endpoint
already contain the synthetic names. Their presence is not a security guarantee:
source permissions do not automatically protect the mirrored paths. Semantic
model row-level security also does not automatically protect those paths or a
future GraphQL API. `SecurityAccessGrant` contains staged test pairs, but those
records do not enforce security or grant user access. Restricted-user and
bypass tests remain outstanding.

## Repository layout

| Path | Purpose |
| --- | --- |
| `sql/` | Operational schema, deterministic seed and names, analytical snapshots, migration, and validation queries. |
| `data/sources/` | Deterministic timetable, regional holiday, PostgreSQL facilities and Cosmos incident source files with checksums. |
| `postgres/` | PostgreSQL facilities schema and post-seed validation scripts, applied and checked against the Azure source. |
| `semantic-model/` | Parameterized TMDL definition and proposed, unvalidated security role. |
| `fabric/` | Data Agent and Foundry instructions, test questions, SQL Bronze table contract, and the Medallion pipeline definition. |
| `notebooks/` | Cell-marked Python sources for the SQL-mirror slice and four-source enrichment. |
| `scripts/` | PowerShell deployment helpers and Python notebook-authoring and Foundry tooling. |
| `tests/` | Local tests for notebook and pipeline contracts, Foundry helpers, and Lakehouse provisioning. |
| `docs/medallion-architecture.md` | Target data flow, agent-ready models and security gates. |
| `AGENTS.md` | Project requirements, deployment status, security constraints, and pending acceptance gates. |
| `settings.example.ps1` | Local configuration template; no credentials belong in this file. |

## Prerequisites and configuration

Use an existing Fabric workspace with a suitable paid capacity, an empty Fabric
SQL Database for a new installation, and an existing Foundry project and model
deployment. Fabric IQ and other features may be in preview and can incur
costs. Do not change tenant settings or create paid infrastructure without the
appropriate approval.

Local tools include Azure CLI, PowerShell 7, the Go version of SQLCMD, and
Python 3.10 or later. Authenticate with an authorized Azure CLI identity
without changing a shared default subscription. Copy `settings.example.ps1` to
`settings.local.ps1`, fill in your own resource identifiers and a valid
`SnapshotDate`, and load it with `. .\settings.local.ps1`. The local file and
`.foundry/` outputs are ignored by Git. Never put credentials, tokens, or real
personal identifiers in them or in source control.

The seed currently models the 2026-2027 school year. `SnapshotDate` must be
at least `2026-08-17` and no later than the current UTC date. The exact
attendance and assessment counts above apply to the deployed
`2026-11-20` snapshot; earlier cutoffs yield different observation counts.

## Initialize an empty SQL database

These scripts create objects and data. Inspect the target first; do not rerun
them against the existing populated database. The commands below obtain a
SQL-audience token for the selected subscription, check its tenant, and pass it
through a process environment variable rather than a command argument or file.
Use a SQLCMD version supporting `ActiveDirectoryServicePrincipalAccessToken`.

```powershell
. .\settings.local.ps1
$token = & az account get-access-token --subscription $SubscriptionId `
    --resource 'https://database.windows.net/' --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) {
    throw 'Unable to acquire a SQL access token.'
}
$payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
$payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
    ConvertFrom-Json
if ($claims.tid -ne $TenantId) {
    throw 'The SQL access token belongs to a different tenant.'
}

$previousSqlPassword = $env:SQLCMDPASSWORD
try {
    $env:SQLCMDPASSWORD = $token
    $files = @(
        '.\sql\schema.sql',
        '.\sql\synthetic-names.sql',
        '.\sql\seed.sql',
        '.\sql\validate.sql',
        '.\sql\analytics.sql',
        '.\sql\analytics-subject-enrollment.sql',
        '.\sql\validate-analytics.sql',
        '.\sql\validate-analytics-subject-enrollment.sql',
        '.\sql\validate-synthetic-names.sql'
    )
    foreach ($file in $files) {
        & sqlcmd -S $SqlServer -d $SqlDatabase `
            --authentication-method ActiveDirectoryServicePrincipalAccessToken `
            -U token -b -v "SnapshotDate=$SnapshotDate" -i $file
        if ($LASTEXITCODE -ne 0) { throw "SQL script failed: $file" }
    }
}
finally {
    if ($null -eq $previousSqlPassword) {
        Remove-Item Env:\SQLCMDPASSWORD -ErrorAction SilentlyContinue
    } else {
        $env:SQLCMDPASSWORD = $previousSqlPassword
    }
    $token = $null
}
```

The fresh-installation order above has not been independently exercised on a
new empty Fabric database since the name changes. For an existing pre-name
snapshot, inspect it first and use `synthetic-names.sql` followed by
`migrate-synthetic-names.sql` and `validate-synthetic-names.sql` instead of
rerunning the schema or seed. The migration refuses existing name columns and
requires the existing analytical learner snapshot. Never run it on the already
migrated deployment.

Verify that all required tables and columns have mirrored to OneLake and the
SQL analytics endpoint before deploying or refreshing the semantic model.
Mirroring is asynchronous; an endpoint metadata refresh may be required.

## Generate and land timetable sources

The generator rebuilds the fictional timetable, the holiday reference
(including previous-school-year summer dates), the HorizonDB seed CSVs, and
`postgres/horizondb_seed.sql` deterministically. Batch
`timetable-2026-2027-v2` is the current immutable landing; the earlier `v1`
files remain preserved and must not be used.

Git and the generators preserve LF for CSV/JSONL files and CRLF for manifests
and the PostgreSQL seed, matching the existing immutable landing bytes on
every supported platform. A changed delivery requires a new batch rather than
overwriting the landed files.

```powershell
py -3 .\scripts\generate_timetable.py
.\scripts\deploy-timetable-sources.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId
.\scripts\deploy-timetable-sources.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId -VerifyOnly
.\tests\test_timetable_sources.ps1
py -3 -m unittest discover -s .\tests -p 'test_timetable_source.py' -v
```

The uploader checks the active workspace capacity and Bronze item, verifies
the selected subscription and token tenant, refuses to overwrite a path with
different content, and reads back each uploaded file to verify its SHA-256.
It uploads only the raw timetable, holiday extract and source manifest; it
does not transform them, publish a schedule, or grant access. The current
generator reconstructs assignment keys from the synthetic SQL seed; run
`sql/validate-timetable-source.sql` against the source SQL analytics endpoint
before adding a downstream transformation. The current snapshot matched all
2,485 assignment keys and their class, subject and teacher references.
`sql/validate-calendar-reference.sql` compares the regional dates with the
synthetic SQL school calendar. It found 20 dates still marked instructional
during the optional May 2027 holiday extension; that advisory variance is
documented in the medallion design and was not used to rewrite the SQL calendar.

## HorizonDB source status

No HorizonDB item has been created. The source schema is
[`postgres/horizondb_schema.sql`](./postgres/horizondb_schema.sql), the
generated synthetic seed is `postgres/horizondb_seed.sql`, and post-load
checks are in [`postgres/horizondb_validate.sql`](./postgres/horizondb_validate.sql).
The seed contains 300 rooms and 10 future, explicitly planned room closures.
The source schema enforces each closure's campus-room relationship, and the
validator checks both primary keys and the validated foreign key before checking
the data. These constraints have been tested locally, not deployed to Azure.
For a disposable local PostgreSQL database initialized with the schema and
seed, `psql -v ON_ERROR_STOP=1 -f tests\postgres_facilities_integrity.sql`
tests that duplicate keys, cross-campus references, and deletion of referenced
rooms are rejected. Never point this test at the Azure source or another shared
database.
These scripts have not been run against the Azure source or HorizonDB. The
current HorizonDB onboarding procedure uses the portal. The signed-in
workspace's New item catalog did not list HorizonDB; the cause is unconfirmed.
A Fabric `PostgreSQLDatabase` REST list request succeeded with zero items, but neither
creation eligibility nor the API's applicability to HorizonDB is confirmed.
No HorizonDB creation request was submitted.

The approved Azure PostgreSQL fallback is running in Sweden Central on
General Purpose D2ads v5 with 32 GiB of storage. Entra authentication and
public network access are enabled; password authentication is disabled. The
Azure-services firewall rule allows connection attempts from Azure services
in any subscription, not just this tenant. Authentication is still required.
A temporary client IP rule used for loading was removed. The server incurs
compute and storage costs. The source schema and 300 rooms and 10 closures
were loaded and compared row by row with the synthetic generator. The source
CDC prerequisite and table eligibility checks passed under the administrator.
An encrypted organizational-account cloud connection and a mirrored database
were created in Fabric. Both facilities tables report `Replicating`; their
300 and 10 SQL endpoint rows match the seed that was compared with the source.
This is a point-in-time comparison, not a test of subsequent source changes or
consumer security.

The [Fabric pipeline PostgreSQL connector](https://learn.microsoft.com/en-us/fabric/data-factory/connector-azure-database-for-postgresql-overview)
documents Basic authentication for Script activity, whereas the
[mirroring tutorial](https://learn.microsoft.com/en-us/fabric/mirroring/azure-database-postgresql-tutorial)
also supports an organizational account. Do not assume a Script activity can
seed this Entra-only server. A
[Fabric managed private endpoint](https://learn.microsoft.com/en-us/fabric/security/security-managed-private-endpoints-create)
can connect Spark workloads to PostgreSQL, but does not establish a mirroring
connection. The documented
[NotebookUtils token audiences](https://learn.microsoft.com/en-us/fabric/data-engineering/notebookutils/notebookutils-credentials#get-token)
do not include PostgreSQL. The public mirroring route uses no VNet gateway.

The local `scripts/load_postgres_facilities.py` prepares and validates the
same deterministic rooms and closures in one database transaction. It refuses
to initialize if the `public` schema contains tables, views or sequences,
compares every loaded row with the generator, and supports a read-only
`--verify-only` recheck. Before connecting, it checks that the local timetable,
holiday, room, closure, incident, manifest and SQL-seed files match their
deterministic generators. This checks local files only, not current remote
mirror freshness. It obtains an
Entra token for the selected subscription and verifies its tenant, requires a
trusted PostgreSQL CA bundle and `verify-full` TLS. By default it requires
private RFC 1918 IPv4 addresses; `--allow-public` explicitly selects globally
routable IPv4 addresses instead. The loader does not configure networking or
mirroring.

After an approved route and DNS are configured, set the PostgreSQL
settings locally and temporarily set `PGUSER` to the Entra database
administrator; do not save the user name or a token in project files:

```powershell
. .\settings.local.ps1
$env:PGUSER = '<postgresql-entra-admin-user>'
python .\scripts\load_postgres_facilities.py `
    --subscription-id $SubscriptionId --tenant-id $TenantId `
    --server $PostgresServer --database-name $PostgresDatabase `
    --ca-bundle $PostgresCaBundle --allow-public --verify-only
Remove-Item Env:\PGUSER
```

Add `--verify-only` to recheck an existing snapshot without writes. The CA
bundle must contain the trusted root certificates described in the
[Azure PostgreSQL TLS guidance](https://learn.microsoft.com/en-us/azure/postgresql/security/security-tls-how-to-connect).
This does not validate network, mirror, access restrictions, or other
downstream paths. The loader does not grant replication permissions or Fabric
access. The mirroring role must own both tables and have the database and
`azure_cdc_admin` permissions described in the
[PostgreSQL mirroring tutorial](https://learn.microsoft.com/en-us/fabric/mirroring/azure-database-postgresql-tutorial);
review those grants separately before creating the mirror.

After loading the source, run the same command with `--verify-only` and
`--check-mirroring-readiness` while authenticated as the intended mirroring
role **before creating the mirror**. In a read-only transaction, this checks
`wal_level`, the mirroring flag, `azure_cdc` registration, effective
`azure_cdc_admin` and database `CREATE` permissions, the extension's
`check_prerequisites()` result, and eligibility for both facilities tables.
The [CDC prerequisite check](https://learn.microsoft.com/en-us/fabric/mirroring/azure-database-postgresql-troubleshoot#sql-queries-for-troubleshooting)
reports issues including identity configuration, worker limits, recovery mode,
and publication limits. Missing or non-`OK` status fails explicitly. Once a
publication exists, the publication limit can make this *pre-creation* check
fail; use `--verify-only` without the readiness flag to recheck source rows.
The extended check passed against Azure CDC under the administrator identity.
It does not configure permissions, inspect the role's `LOGIN`/`REPLICATION`
attributes, verify the gateway or actual managed-identity permissions,
establish mirror freshness, or prove downstream access isolation. The
[limitations](https://learn.microsoft.com/en-us/fabric/mirroring/azure-database-postgresql-limitations#permissions-in-the-source-database)
list `LOGIN` and `REPLICATION` for the mirroring role, while the tutorial's
Entra-role example does not explicitly grant them; verify the effective
requirements for the chosen identity rather than assuming either example is
complete.

The PostgreSQL mirror and its owner-created Bronze schema shortcut exist. The
portal selected `public.facility_room` and
`public.facility_closure` with automatic mirroring of future tables disabled.
Fabric reports both tables as `Replicating`; the administrator could read
their Delta logs under `Tables/_public/`. Administrator Spark reads through
`Tables/PostGre/` returned 300 rooms and 10 closures. Restrict and verify
source, workspace and OneLake access before granting consumer access. Review
the encrypted cloud connection and observed OneLake paths before configuring
the placeholder values in
[`settings.example.ps1`](./settings.example.ps1) locally. The two paths must
be under the same `Tables/` folder and end in their exact table names. If the
observed paths differ, stop and review the implementation instead of guessing.

The shortcut preflight accepts an encrypted OAuth cloud or VNet connection.
However, the live mirror's returned definition does not contain
`mountedTables`, so the preflight currently fails closed even though the portal
selection and table statuses show the two expected tables. The
[definition documentation](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/mirrored-database-definition)
says an omitted `mountedTables` means all tables, including future tables,
are mirrored. This conflicts with the portal observation; the effective
selection remains unconfirmed. Do not remove the check without a reliable way
to verify the persistent selection.
The following
**read-only** preflight calls Fabric status and definition APIs and checks
the source Delta logs; it does not create the mirror, gateway, directory, or
shortcuts. Retrieving the definition requires read and write permission on the
mirror, even though the preflight does not update it.

```powershell
. .\settings.local.ps1
.\scripts\deploy-sql-bronze-shortcuts.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId -DatabaseItemId $PostgresMirrorItemId `
    -SourceKind AzurePostgreSql -PostgresMirrorName $PostgresMirrorName `
    -PostgresConnectionId $PostgresConnectionId -PostgresConnectionPath $PostgresConnectionPath `
    -PostgresRoomPath $PostgresRoomPath -PostgresClosurePath $PostgresClosurePath -PreflightOnly
.\tests\test_postgres_bronze_shortcuts.ps1
```

The preflight requires the reviewed encrypted OAuth cloud or VNet connection, an
explicit two-table mirror definition, `Running`/`Replicating` statuses and
accessible Delta logs. Status and timestamps do not prove row equality or
freshness. Independently compare every source and mirrored row, confirm the
pipeline identity's access, and enforce and test restrictions across the
source, mirror, OneLake and Bronze before exposing any path.
[`fabric/POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED`](./fabric/POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED)
is retained until those gates pass; it is not an access control and did not
prevent the owner-created shortcut. The script no longer creates legacy
`Files` shortcuts, even if the marker is removed. `-VerifyOnly` checks the
schema shortcut after the same strict mirror preflight; the live definition
still fails that preflight. The checks do not prove restricted-user isolation.

## Deploy and test

`scripts/deploy-lakehouses.ps1` creates the three schema-enabled Lakehouses on
the configured workspace's active capacity. It checks existing items before
creation, waits for provisioning and checks the SQL endpoint properties. It
does not upload data or grant permissions. Review workspace access separately:
separate Lakehouses in one workspace are not an isolation boundary. OneLake
storage and Fabric compute can incur charges.

```powershell
. .\settings.local.ps1
.\scripts\deploy-lakehouses.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId
# Check existing items without creating missing ones:
.\scripts\deploy-lakehouses.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId -VerifyOnly
.\tests\test_lakehouse_deployment.ps1
```

`scripts/deploy-sql-bronze-shortcuts.ps1` now only verifies the existing
`sql` schema shortcut and the reviewed operational tables in
`fabric/sql-bronze-tables.json`. `scripts/deploy-cosmos-bronze-shortcut.ps1`
similarly verifies `CosmosDB`. Both refuse legacy `Files` shortcut creation.
Their administrator Delta-log checks do not prove mirror freshness,
pipeline identity access, or restricted-user permissions.

```powershell
.\scripts\deploy-sql-bronze-shortcuts.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId -DatabaseItemId $DatabaseItemId -VerifyOnly
.\scripts\deploy-cosmos-bronze-shortcut.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId -VerifyOnly
.\tests\test_sql_bronze_shortcuts.ps1
.\tests\test_cosmos_bronze_shortcut.ps1
```

`scripts/deploy-medallion-notebooks.ps1` deploys the two SQL notebook
definitions, or the two enrichment definitions with `-OnlyEnrichment`, binding
Bronze-to-Silver to the Bronze Lakehouse and Silver-to-Gold to Silver. It
verifies the active-capacity workspace and only updates notebooks with the
expected project descriptions. Inspect existing notebook metadata before using
it to update a definition. It does not execute Spark, materialize tables, or
grant permissions.

```powershell
.\scripts\deploy-medallion-notebooks.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId
```

`scripts/deploy-semantic-model.ps1` deploys the parameterized model to a
workspace after checking that the database exists and the model name is unused.
`scripts/deploy-data-agents.ps1` creates and publishes the configured agents;
its update mode requires explicit `-UpdateExisting`. Inspect drafts, selections,
runtime settings, and permissions before publishing. Do not use these scripts
to replace unrelated resources or share an unsecured model.

`scripts/foundry_agent.py` creates the Foundry agent and its delegated
connections or asks the deployed agent a question. It takes resource values
as command-line options and refuses to replace an existing agent. Its local
configuration may be newer than an already deployed agent version.
`scripts/foundry_eval.py` manages generated evaluation drafts; review the
questions, expected results, traces, and safety checks before using them.
Obtain owner approval before running a batch evaluation.

For local unit tests:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python -m unittest discover -s tests -v
```

Local unit tests do not validate live Fabric permissions, mirroring, or
restricted-user behavior. Before any sharing, independently test allowed and
denied campus/department pairs, overlapping departments, users without grants,
and bypass attempts for each exposed path. GraphQL also needs a verified
read-only schema, key discovery, delegated permissions, and source SSO.

## Project workflow

After the initial repository bootstrap, use GitHub issues, branches, commits,
and pull requests for changes. Keep project content in English, maintain
`AGENTS.md`, and document unverified capabilities rather than claiming they
are deployed.
