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
files and a PostgreSQL facilities source through separate Bronze, Silver and
Gold Lakehouses. Two Gold-backed semantic models will serve the Data Agents
and Foundry. Fabric HorizonDB is the preferred PostgreSQL source; it is a
public preview. The three Lakehouses have no materialized tables. Bronze now
has 20 administrator-verified shortcuts to allowlisted SQL-mirror
tables; physical ingestion and the rest of the target architecture are
**not yet deployed**.
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
| Medallion architecture | Three schema-enabled Lakehouses and their SQL endpoints are deployed. Bronze has 20 allowlisted SQL-mirror shortcuts, verified as an administrator; no tables have been materialized. PostgreSQL facilities and Gold-backed models are not yet deployed, and restricted access is unverified. |
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
| `semantic-model/` | Parameterized TMDL definition and proposed, unvalidated security role. |
| `fabric/` | Data Agent and Foundry instructions, test questions, and the SQL Bronze table contract. |
| `scripts/` | PowerShell deployment helpers and Python Foundry deployment, query, and evaluation helpers. |
| `tests/` | Local tests for the Foundry helpers and Lakehouse provisioning. |
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
