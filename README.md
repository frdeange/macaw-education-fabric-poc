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
PostgreSQL source; it is a public preview. Bronze has 20 administrator-verified shortcuts to
allowlisted SQL-mirror tables. The SQL-mirror-only Bronze-to-Silver-to-Gold
notebook slice and sequential `Macaw Education Medallion` pipeline are
deployed. The first run exposed an attendance-count contract error: 315,842 is
the Present-or-Late numerator, while 336,000 is the total observed
instructional student-days. After correcting the contract, the pipeline
completed. Silver and Gold products and validated manifests were read back
through their SQL analytics endpoints. The pipeline has no schedule or
external failure-notification connection. A reproducible timetable and
regional holiday batch is landed in Bronze as immutable raw files. Cosmos
contains 20 fictional incident documents and 40 history events; its mirror
and Bronze shortcut were checked against the source. Azure PostgreSQL is
running with an empty facilities database, but has no seeded tables or mirror.
An interrupted enrichment run left partial Silver tables and a `Staging`
manifest; those tables are not validated products. The draft enrichment
notebooks are blocked until the PostgreSQL mirror is integrated.
See the [medallion design](./docs/medallion-architecture.md) for source,
security and validation requirements.

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
| Medallion architecture | Three schema-enabled Lakehouses are deployed. The SQL-only pipeline and its Silver/Gold manifests were validated as an administrator. Bronze also contains immutable `timetable-2026-2027-v2` files and a checked Cosmos mirror shortcut. An interrupted enrichment run left 2,485 timetable, 21 holiday and 20 incident rows in partial Silver tables with a `Staging` manifest; the event table and enrichment Gold products are absent. Both deployed draft notebooks explicitly fail until the PostgreSQL mirror is integrated. These staging tables are not validated or safe to share. |
| Cosmos DB incidents | The synthetic container holds 20 incidents and 40 history events. All documents were compared with the OneLake mirror, and the Bronze shortcut was verified. Restricted-user access remains unverified. |
| PostgreSQL facilities | The approved fallback server is running with public network access and password authentication disabled. An empty `macaw_facilities` database, an Entra administrator and a system-assigned identity exist; the 300-room/10-closure seed, private connectivity and mirroring remain pending. The server incurs compute and storage costs. |
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
| `postgres/` | PostgreSQL facilities schema and post-seed validation scripts; not yet executed. |
| `semantic-model/` | Parameterized TMDL definition and proposed, unvalidated security role. |
| `fabric/` | Data Agent and Foundry instructions, test questions, SQL Bronze table contract, and the Medallion pipeline definition. |
| `notebooks/` | Cell-marked Python sources for the SQL-mirror slice and blocked enrichment drafts. |
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
These scripts have not been run against a live database. The current HorizonDB
onboarding procedure uses the portal. The signed-in workspace's New item
catalog did not list HorizonDB; the cause is unconfirmed. A Fabric
`PostgreSQLDatabase` REST list request succeeded with zero items, but neither
creation eligibility nor the API's applicability to HorizonDB is confirmed.
No HorizonDB creation request was submitted.

The approved Azure PostgreSQL fallback is running in Sweden Central on
General Purpose D2ads v5 with 32 GiB of storage. Entra authentication is
enabled, password authentication and public network access are disabled.
The empty `macaw_facilities` database, a project-tenant Entra administrator and
a system-assigned managed identity were created. No Fabric permissions were
granted to that identity. The supported PostgreSQL mirroring preparation
command completed; `azure.fabric_mirror_enabled` is `on` and `wal_level` is
`logical`. The reported extension allowlist and preload values do not show
`azure_cdc`, so its registration and readiness remain unverified. Private
connectivity, schema, seed and the Fabric mirror remain pending. The running
server incurs compute and storage costs. A VNet data
gateway could use 4 capacity units per member while active, potentially
competing with this shared F4 capacity; obtain approval before activating it.
Do not create a new paid capacity or change shared workspace networking
without the required approval.

The [Fabric pipeline PostgreSQL connector](https://learn.microsoft.com/en-us/fabric/data-factory/connector-azure-database-for-postgresql-overview)
documents Basic authentication for Script activity, whereas the
[mirroring tutorial](https://learn.microsoft.com/en-us/fabric/mirroring/azure-database-postgresql-tutorial)
also supports an organizational account. Do not assume a Script activity can
seed this Entra-only server. A
[Fabric managed private endpoint](https://learn.microsoft.com/en-us/fabric/security/security-managed-private-endpoints-create)
can connect Spark workloads to PostgreSQL, but Entra authentication for a
seed notebook and its use for mirroring remain unverified.

Once a supported private Entra-authenticated loading path is available, apply
schema, seed, then validation; wait for the asynchronous mirror and validate
the analytics endpoint before adding facilities to Silver or Gold.

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

`scripts/deploy-sql-bronze-shortcuts.ps1` creates or verifies individual
OneLake shortcuts for the reviewed operational tables in
`fabric/sql-bronze-tables.json`. It excludes analytical snapshots and security
grants, refuses conflicting paths and checks access to each target's Delta-log
directory. The shortcuts do not copy data, prove mirror freshness, or
establish permissions for a future pipeline identity.

```powershell
.\scripts\deploy-sql-bronze-shortcuts.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId -DatabaseItemId $DatabaseItemId
.\scripts\deploy-sql-bronze-shortcuts.ps1 -SubscriptionId $SubscriptionId `
    -TenantId $TenantId -WorkspaceId $WorkspaceId -DatabaseItemId $DatabaseItemId -VerifyOnly
.\tests\test_sql_bronze_shortcuts.ps1
```

`scripts/deploy-medallion-notebooks.ps1` deploys the two version-controlled
notebook definitions, binding Bronze-to-Silver to the Bronze Lakehouse and
Silver-to-Gold to Silver. It verifies the active-capacity workspace and only
updates notebooks with the expected project descriptions. It does not execute
Spark, materialize tables, or grant permissions.

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
