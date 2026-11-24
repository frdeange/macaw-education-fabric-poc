# Macaw education project

## Project context

Build a Microsoft Fabric and Microsoft Foundry proof of concept for a partner
working in the Netherlands. Educational data must be entirely synthetic.

Project content, including code, documentation, data labels, agent
instructions, and user-facing examples, must be in English. Retain Dutch
educational terms where they are useful or have no direct English equivalent.
Communicate with the project owner in Spanish unless asked otherwise.

The deployment uses a Fabric workspace on an active paid capacity and an
existing Foundry project and model deployment. Environment
identifiers belong in the ignored `settings.local.ps1`, not in the public
repository; `settings.example.ps1` documents the required configuration.

The local Azure CLI may have multiple identities and a different default tenant.
For Fabric API access, select the target subscription explicitly when obtaining
a token and verify its tenant; do not change the shared global Azure CLI
default. Pass environment-specific values to reusable scripts as configuration.
Do not commit credentials, tokens, personal identifiers, or environment-specific
resource identifiers. With the installed
`AzureCliCredential`, configure the subscription and verify the token's tenant;
passing both a subscription and tenant to Azure CLI token acquisition fails.

## Outcomes

1. Create a SQL database in Fabric and populate a consistent Dutch education
   scenario with synthetic data.
2. Create and validate a Power BI semantic model for analytical and
   conversational use.
3. Configure and publish two Fabric Data Agents, specialized in school
   operations and learning outcomes.
4. Expose both conversational access and a structured, read-only API for
   external consumers. The intended consumers are users from the same
   Microsoft Entra tenant.
5. Connect the two published Data Agents to a Microsoft Foundry agent through
   Fabric IQ. Foundry configuration and tests must be implemented in Python
   scripts that are part of the project.
6. Deploy Fabric artifacts programmatically where supported, and verify the
   resulting artifacts and integrations. Do not report a planned artifact as
   deployed.

## Dutch education scenario

Use the following initial design unless the project owner changes it:

- Five fictional education campuses, each representing a primary school unit
  and a secondary school unit. This is a fictional administrative grouping,
  not a claim that the Dutch system normally combines them in one school.
- Proposed fictional campuses are `Macaw Amsterdam Campus`, `Macaw Utrecht
  Campus`, `Macaw Rotterdam Campus`, `Macaw Eindhoven Campus`, and `Macaw
  Groningen Campus`. Amsterdam and Groningen use the North school-holiday
  region; Utrecht and Rotterdam use Central; Eindhoven uses South.
- Eight primary year levels, `Primary Group 1` through `Primary Group 8`.
- Six possible secondary year levels, `Secondary Year 1` through
  `Secondary Year 6`. Track eligibility must follow actual programme lengths:
  VMBO lasts four years, HAVO five, and VWO six.
- Four class sections per campus and year level, with 20 distinct students per
  class in the initial academic-year snapshot. Four sections are shared among
  applicable tracks; they are not four sections per track.
- Exact snapshot totals: five campuses, 14 year levels per campus, 280 class
  sections, and 5,600 distinct students. Each secondary track should be
  represented in its applicable year levels.

The snapshot is fictional. Do not invent historical student progression merely
to explain the class distribution. If additional academic years are generated,
model enrolments and student progression explicitly instead of multiplying
headcounts.

Model school units, academic years, year levels, class sections, students,
enrolments, teachers, departments, subjects, teaching assignments, attendance,
assessments, and assessment results as appropriate. Select subject offerings
according to education stage, year, and track rather than assigning every
subject to every pupil. Illustrative subject areas include Dutch, English,
mathematics, social and environmental studies, science and technology, creative
expression, and physical education. Departments are fictional organisational
units, not a prescribed national structure. Suitable starting departments are
Languages, Mathematics, Science and Technology, Social and Environmental
Studies, Creative Arts, and Physical Education.

Account for early primary groups' play-based learning. Do not impose numeric
examinations on all primary groups. Where secondary assessment marks are
simulated, use the Dutch 1-to-10 scale and do not treat one simple threshold as
the complete national school-leaving examination rule.

Represent relevant upper-secondary specialisations only at eligible stages:
HAVO and VWO have subject combinations in their upper years, while VMBO has
different pathways and profiles. The HAVO and VWO combinations are Science
and Technology, Science and Health, Economics and Society, and Culture and
Society. VMBO graduates may progress to vocational education (MBO); a VMBO
diploma alone is not the same as a basic qualification.
The first version models primary and secondary education; MBO and higher
education are out of scope. It must not claim regulatory completeness.

Use configurable academic dates and a school calendar appropriate to each
campus. Dutch school holidays vary across the North, Central, and South
regions; some holiday dates are advisory and schools may deviate. Generate
attendance only for actual simulated instructional days and never present
future events as observed facts.

Use artificial student identifiers, not real pupil information, BSNs, or
other official personal identifiers. Do not infer sensitive characteristics or
label individual pupils as being at risk. Operational Entra identities needed
for security tests are not synthetic educational data and must not be committed.

The project owner also wants fictional first and last names for students and
teachers to support future demos. Generate them reproducibly, using names
plausible in the Netherlands without copying real people's records. Support
Unicode, spaces, and compound surnames such as those with Dutch surname
particles. Names may coincide with real names and are not unique identifiers:
retain the existing keys and artificial student and teacher codes. Do not infer
sensitive characteristics from names or create real contact details.

## Architecture and security

- Fabric SQL Database is the operational source. Its supported tables are
  mirrored to OneLake and made available through a SQL analytics endpoint;
  replication is asynchronous. Verify mirroring before downstream validation.
- The target medallion design uses separate Bronze, Silver and Gold Lakehouses
  in one suitable development workspace. Ingest the SQL mirror, synthetic
  timetable CSV files, synthetic Cosmos DB incidents, and a synthetic
  facilities source in Fabric HorizonDB (public preview), with Azure
  PostgreSQL Flexible Server as the approved fallback if HorizonDB is
  unavailable. Gold-backed models will serve the two
  Data Agents and Foundry. See `docs/medallion-architecture.md`. The three
  Lakehouses and SQL endpoints exist; Bronze has owner-created schema shortcuts
  for the SQL, Cosmos and PostgreSQL mirrors. The SQL-only pipeline was rerun
  and validated after the shortcut migration. The four-stage SQL and
  four-source enrichment pipeline completed, and its Silver and Gold
  manifests and totals were validated.
  Raw timetable and holiday files remain in Bronze. Restricted-user access
  remains unverified.
- Design the semantic model around clear facts, dimensions, relationships,
  measures, and documented denominators. Prefer the mirrored OneLake data and
  validate the supported storage mode and security behaviour in the target
  environment.
- Both Fabric Data Agents should use supported sources, preferably the curated
  semantic model, with English instructions and representative questions.
  The proposed School Operations agent covers enrolment, class sizes, and
  attendance; the Learning Outcomes agent covers assessments by subject,
  department, year, and track. Publish them before testing their MCP endpoints.
- Provide conversational access through the published Data Agent MCP
  endpoints. For structured access, use Fabric API for GraphQL with delegated
  Microsoft Entra authentication and only the intended read-only objects and
  operations. Validate actual permissions and the generated API schema.
- Implement real access restrictions by campus and department. The owner
  authorized the selected test identities and their pair grants. Access is
  granted to specific campus/department pairs, not the cross-product of
  separate campus and department lists. For enrolment and attendance, a
  department-restricted user may see only students taking at least one subject
  in an authorized department at an authorized campus. Apply the same rule to
  every exposed path, and test with appropriately restricted users, not only
  workspace administrators.
- Security is a cross-surface requirement. Semantic-model RLS does not
  automatically secure GraphQL, the source SQL database, the mirrored SQL
  analytics endpoint, or OneLake. Source database granular security is not
  automatically copied to the mirrored endpoint. Enforce and test suitable
  protections separately for every exposed path; do not expose a path whose
  effective access cannot be verified.
- The Foundry agent should route school operations and learning questions to the
  appropriate Fabric Data Agent via Fabric IQ. Use the signed-in user's
  delegated identity and verify that authorised and unauthorised users receive
  appropriate results. Use a managed prompt agent configured and tested with
  Python.
- Fabric IQ and the Data Agent SDK include preview features. Verify the paid
  Fabric capacity, region, tenant settings, permissions, model availability,
  networking, data-processing boundaries, and expected costs before deployment.
  Do not change tenant settings or create new paid infrastructure without the
  appropriate approval.

## Implementation and verification

- Inspect existing assets before creating or modifying anything; do not replace
  unrelated resources. Parameterize environment-specific settings.
- Make data generation reproducible and validate keys, relationships,
  year-level and track eligibility, section sizes, and the exact snapshot
  totals above.
- Add separate first-name and last-name fields for students and teachers to
  the SQL schema and reproducible seed data. Migrate the existing synthetic
  snapshot without changing its keys or enrollment relationships, and update
  the analytical tables and semantic model needed for future demos. Validate
  the names and their replication, and enforce and test the appropriate access
  restrictions before exposing them through any consumer-facing surface.
- Validate the database, mirrored data, semantic-model measures, both published
  Data Agents, each MCP endpoint, the GraphQL schema and read-only behaviour,
  and the Foundry-to-Fabric IQ end-to-end flow.
- Test authorised and denied access across campus and department boundaries,
  including the structured API. Document any unverified capability or manual
  step instead of claiming success.
- Keep this file current as decisions are made. Distinguish confirmed
  requirements, proposed choices, unresolved questions, and actual deployment
  status.
- After the initial repository bootstrap, manage changes through GitHub issues,
  branches, commits, and pull requests.

## Deployment status

- The owner deleted the earlier `Macaw Education` semantic model and the two
  original Data Agents because they used the wrong source. Earlier model and
  agent deployment and smoke-test results below are historical. The existing
  Foundry version still references those deleted agents and is not a verified
  path to the new Gold agents.
- Two unshared Direct Lake models, `Macaw Gold School Operations` and
  `Macaw Gold Learning Outcomes`, now use detailed Gold facts. Both refreshed;
  administrator DAX checks returned 5,600 students, 280 classes, 336,000
  student-days, 2,485 weekly assignments, 20 incidents, 17 planned overlaps
  and 87,100 assessment results. Department selection and the absence of
  subject-level attendance were also checked in DAX.
- Their published, unshared Data Agents returned correct Dutch enrollment and
  qualitative-outcome results in administrator MCP smoke tests. Operations
  initially misrepresented overall attendance as Dutch lesson attendance;
  one retest correctly declined after instructions changed, but a department
  student-day question was incorrectly rejected as unsupported, even after
  stale Data Agent element descriptions were corrected and republished. A
  Power BI schema response still showed old aggregate metadata after the
  model update; its cause is unconfirmed. Do not treat the agents as reliable or connect
  them to Foundry until investigated and retested. Prep data for AI and
  restricted-user security remain open.
- Three schema-enabled Lakehouses, `MacawEducationBronze`,
  `MacawEducationSilver` and `MacawEducationGold`, have been created in the
  project workspace. `Macaw Bronze to Silver` and `Macaw Silver to Gold`
  notebook definitions were deployed and bound to the Bronze and Silver
  Lakehouses. The initial SQL-only `Macaw Education Medallion` pipeline
  definition was deployed and read back with its four activities and
  parameters. The first run failed twice in
  Bronze-to-Silver because the 315,842 Present-or-Late attendance numerator
  was mistakenly used as the expected total record count. The corrected
  count is 336,000 observed instructional student-days through the snapshot
  date. A subsequent run completed both notebook activities. SQL endpoint
  validation confirmed Silver fact counts of 5,600, 43,550, 336,000 and
  87,100, plus validated Silver and Gold manifests. Gold aggregate totals
  are 5,600 enrollment learners, 5,600 class-size learners, 43,550 subject
  enrollments, 336,000 attendance records and 87,100 assessment results.
  The Present-or-Late numerator remains 315,842. The SQL-only pipeline was
  rerun after the schema-shortcut migration and the manifests and Silver
  counts were validated again.
  No pipeline schedule, external failure-notification connection or
  permissions were configured. HorizonDB remains planned; restricted-user
  access to the Lakehouses and their endpoints is unverified.
- The owner replaced the SQL and Cosmos `Files` shortcuts with three Bronze
  schema shortcuts: `sql`, `CosmosDB` and `PostGre`. CSV files remain under
  `Files`. OneLake's table catalog lists 27 SQL tables, one Cosmos table and
  two PostgreSQL tables. The SQL shortcut exposes the 20 operational tables
  in `fabric/sql-bronze-tables.json` plus six `Analytics*` tables and
  `SecurityAccessGrant`. The 20-table processing contract is not a security
  boundary; future source tables may also become visible.
- Administrator Spark reads through the schema shortcuts returned 5,600 SQL
  students, 2,485 teaching assignments, 20 Cosmos incidents, 300 PostgreSQL
  rooms and 10 closures. The SQL and Cosmos verify-only scripts checked
  shortcut targets and Delta-log access. A live Bronze SQL analytics endpoint
  query returned all three schemas: `sql` (27 tables), `CosmosDB` (one table)
  and `PostGre` (two tables). The read-only metadata sync status check reported
  legacy `V1` with no migration attempt; despite this, the schemas and tables
  are queryable. A separate pipeline identity and restricted users have not
  been tested. Source and mirrored counts for all 20 SQL tables matched,
  the declared source primary keys matched, and the source change-feed states
  were `Active`. These checks do not prove row-level equality, a consistent
  cross-table snapshot or mirror freshness. No SQL Bronze Delta materialization
  has run.
- All four SQL and enrichment notebook definitions use the schema paths.
  The four-stage pipeline definition and its failure paths were deployed and
  read back. The pipeline and all four notebook activities completed.
- A point-in-time workspace role inventory and the Bronze Lakehouse and SQL
  endpoint item-access inventories each listed only the signed-in workspace
  administrator. Bronze and the PostgreSQL mirror each had only a
  `DefaultReader` OneLake role granting `ReadAll` holders access to all paths.
  These observations do not establish a campus/department policy, effective
  restricted-user isolation or the SQL endpoint's access mode.
  A later workspace role inventory again showed one administrator assignment;
  Azure CLI listed one user identity for the project tenant. Neither inventory
  proves effective item access or supplies restricted-user credentials.
- The reproducible synthetic timetable and holiday batch
  `timetable-2026-2027-v2` is present in immutable Bronze landing paths. The
  uploaded files contain 2,485 planned weekly assignments, 21 official
  regional holiday rows, and a source manifest; remote SHA-256 readback passed.
  An earlier immutable `v1` batch with 18 holiday rows remains in Bronze and
  is superseded; use only the `v2` paths. A read-only SQL analytics endpoint
  comparison reconstructed 2,485 source teaching assignments with zero
  mismatched keys, sections, subjects, or teachers.
- The holiday reference includes 2025-2026 summer dates to check the start of
  the 2026-2027 snapshot. A SQL analytics endpoint comparison found 20 dates
  marked instructional during the optional 2027 May holiday extension (four
  dates at each of five campuses); the dates are advisory. The SQL school
  calendar was not changed.
- Synthetic HorizonDB seed data and PostgreSQL DDL/validation scripts are
  versioned under `data/sources/horizondb/` and `postgres/`: 300 rooms and 10
  planned room closures. No HorizonDB item was created; the DDL and seed
  were applied to Azure PostgreSQL. In the signed-in
  Fabric portal, the workspace's New item catalog did not offer HorizonDB,
  and no HorizonDB-specific tenant setting was visible. The reason is
  unconfirmed; preview eligibility and capacity/cost review remain open.
  The local source schema enforces the campus-room relationship, and its
  validator checks the primary keys and validated foreign key. These checks
  passed against the Azure source.
- An Azure PostgreSQL Flexible Server fallback was provisioned while
  HorizonDB availability was still unconfirmed. It is now Ready in Sweden
  Central on the General Purpose D2ads v5 tier, with 32 GiB of storage,
  Microsoft Entra authentication enabled, password authentication disabled,
  and public network access enabled. It incurs compute and storage charges.
  The `macaw_facilities` database, an Entra administrator in the
  project tenant and a system-assigned managed identity exist. The 300 rooms
  and 10 closures were loaded and verified row by row. Fabric's tutorial says
  mirror creation automatically grants that identity read/write on the mirror;
  the effective grant has not been independently audited.
  An Azure-services firewall rule allows connection attempts from all Azure
  subscriptions, while Entra authentication remains required. A temporary
  client IP rule used for seeding was removed. Consumer security remains
  unverified.
- A read-only subscription inventory visible to the current identity found
  one VNet outside the project resource group and no subnet delegated to Power
  Platform in that VNet; its ownership and suitability are unverified. No
  accessible private endpoint targeted the PostgreSQL server, and local DNS
  returned no RFC 1918 IPv4 address during the earlier check. These checks are
  permission-limited and point-in-time; do not modify the existing VNet without
  approval.
- The Fabric Azure PostgreSQL pipeline connector documents Basic
  authentication for Script activity; the mirroring tutorial separately
  supports organizational accounts. The server has passwords disabled.
  Fabric managed private endpoints support PostgreSQL for Spark workloads,
  not a documented mirroring connection. The documented NotebookUtils token
  audiences do not include PostgreSQL. The source was seeded via its public
  endpoint using Entra authentication and verified TLS.
- The supported PostgreSQL `fabric-mirroring start` preparation command
  completed before loading the facilities database. Readback shows
  `azure.fabric_mirror_enabled=on` and `wal_level=logical`, with the server
  Ready. The administrator's read-only CDC prerequisites and both table
  eligibility checks passed against the database.
- The PostgreSQL loader has an optional, read-only source readiness check for
  CDC registration, effective role permissions, the extension's
  pre-creation `check_prerequisites()` result and table eligibility. Its
  extended logic passed local tests and the administrator check against Azure
  CDC, but does not verify the Fabric connection, replication, freshness or
  downstream isolation.
  The mirrored school calendar marks both planned closure dates instructional
  for all five campuses; the 17 schedule overlaps are plans, not observed
  lessons or incidents.
- The PostgreSQL mirror was created through the portal using an encrypted
  organizational-account cloud connection without a gateway. The two
  facilities tables were selected with automatic mirroring of future tables
  disabled. Both report `Replicating`, and the SQL endpoint's 300 rooms and
  10 closures match the previously validated source seed row by row. Delta
  logs were observed under `Tables/_public/`. This point-in-time comparison
  does not test subsequent source changes or restricted-user isolation.
- The PostgreSQL schema shortcut exists, but its strict read-only preflight
  fails closed: the live mirror definition omits `mountedTables`. The
  definition documentation says omission selects all tables including future
  ones, conflicting with the portal observation; effective persistent
  selection is unconfirmed. Successful preflight tests use simulated
  responses. Neither the preflight nor the Spark counts establish freshness,
  pipeline access or isolation. The retained
  `fabric/POSTGRES_SHORTCUT_DEPLOYMENT_BLOCKED` marker is not an access
  control and did not prevent the owner-created shortcut. The included script
  no longer creates legacy `Files` shortcuts.
- The synthetic Cosmos DB container contains 20 incidents and 40 history
  events. The 20 mirrored documents were compared in full with their seed,
  and the Bronze shortcut to the Cosmos mirror was verified. Events are
  observed only through the snapshot date. Shared room identifiers do not
  prove that an incident caused a planned PostgreSQL closure.
- An earlier interrupted enrichment run reported `Completed` despite a
  `Staging` manifest and incomplete tables. A later four-source Silver run
  replaced those partial tables: after SQL metadata refresh, its validated
  manifest and endpoint counts showed 2,485 planned assignments, 21 holiday
  rows, 300 rooms, 10 planned closures, 20 incidents and 40 events. It found
  17 planned closure/assignment overlaps, no capacity exceedances and 20
  advisory holiday-calendar variances. The four-stage pipeline was then run;
  SQL endpoint readback confirmed all four validated manifests and matching
  totals. Bidirectional comparisons of Silver rooms and closures with the
  Bronze mirror found no differences, and an independent SQL reconstruction
  matched all closure/assignment impact keys. This administrator validation
  does not establish source freshness or restricted-user security.
- A documented Fabric REST API for `PostgreSQLDatabase` exists and lists zero
  items in the workspace, but its applicability to HorizonDB has not been
  confirmed. A successful list call does not prove that creation is enabled.
  No HorizonDB creation request was submitted.
- The Fabric SQL database `MacawEducation` was created in the project
  workspace.
- The database is reachable with SQLCMD using a SQL token acquired for the
  project subscription. `sql/schema.sql` and `sql/seed.sql` were applied and
  `sql/validate.sql` passed. The snapshot contains five campuses, 280 classes,
  5,600 students, 336,000 attendance records, and 87,100 assessment results.
- The SQL analytics endpoint exposes all 20 source tables. Its counts for
  campuses, classes, students, attendance, and assessment results match the
  source database. Mirroring is asynchronous.
- Six additional analytical tables have been materialized in SQL and mirrored.
  Their learner, learner-department, attendance, and assessment counts are
  5,600, 31,450, 336,000, and 87,100 respectively on the analytics endpoint.
  These tables are a snapshot: subsequent operational changes do not
  automatically update them.
- `SecurityAccessGrant` contains nine staged campus-department pairs for five
  generic test identities; two additional identities have no grants. The SQL
  source and mirrored endpoint match, and an administrator model query returned
  nine records for five principals. The records do not grant access or enforce
  security; restricted-user tests and role membership remain unverified.
- `AnalyticsSubjectEnrollment` has been created and validated in the source SQL
  database and mirrored to the SQL analytics endpoint. It contains 43,550
  distinct student-subject rows, including 960 Dutch students at each campus.
- Deterministic fictional first and last names were added to all 5,600
  students, 240 teachers, and 5,600 analytical learners without changing their
  keys, codes, or enrollment relationships. The source validation passed.
  Following a SQL analytics metadata refresh, row counts, UTF-8 names, and
  SHA-256 digests of the keyed names match the source for all three tables.
  Names can coincide and are not identifiers. The published semantic model
  does not contain these name columns; both Data Agents use only that model.
  The names are nevertheless present in the source and its mirrored paths:
  effective access to those paths is not yet isolated or verified.
- The Direct Lake semantic model `Macaw Education` was created and its initial
  refresh succeeded.
  Measures match SQL totals and campus/department and subject breakdowns,
  including qualitative outcomes with no numeric mark. Its row-level security
  has not been validated; do not treat it as ready for sharing.
- Subject enrollment has been added to the published semantic model and the
  model refreshed. Under an administrator identity, all 105
  campus-subject-department student and class counts matched operational SQL;
  combined campus/track/subject filters, distinct counts, and existing total
  measures also matched. Attendance measures return blank for a subject filter
  rather than an unfiltered count. The new fact and subject dimension have
  proposed role filters, but restricted-user behavior remains untested.
- Two Data Agents were created and published without sharing access:
  `Macaw School Operations` and `Macaw Learning Outcomes`. Both
  have the semantic model as their only published source and their configured
  English instructions and intended table selections were verified after
  publication. MCP tests returned the expected 5,600 students, 87,100
  assessment results, and 315,842 Present-or-Late records out of 336,000
  observed attendance records (94.00%). A test asking how many students take
  Dutch at each campus returned the unfiltered campus totals and invented a
  Dutch department. This is incorrect. That test predates the new
  subject-enrollment model. Both agents
  have since been republished with the updated local configuration. In
  administrator MCP smoke tests, School Operations returned the expected 960
  Dutch students at each campus and Learning Outcomes returned 87,100
  assessment results. School Operations also correctly declined a request
  for Dutch lesson attendance, explaining that attendance is recorded by
  student-day. These tests do not establish general reliability or
  restricted-user security. Do not equate assessment records with enrollment.
  Keep the agents unshared.
- The School Operations draft has `experimental.enableExperimentalFeatures`
  set to `true`, selecting the
  [preview runtime](https://learn.microsoft.com/en-us/fabric/data-science/data-agent-runtime).
  It includes advanced DAX generation and can change more frequently than the
  standard runtime. Publication uses the draft's runtime selection. The
  published-settings response does not expose this flag, so the existing
  prior published runtime and the flag's provenance remain unconfirmed. The
  owner accepted the preview runtime for this proof of concept; it remains a
  Microsoft preview feature, not generally available. The agent was published
  with this draft setting, which remained enabled afterward. Validate the
  resulting agent with representative questions and restricted identities.
- Semantic-model data sources do not support Data Agent few-shot queries;
  representative questions in `fabric/data-agents.json` are test prompts, not
  published few-shot examples. Data Agent instructions are not passed to the
  semantic model's DAX generator. Model-specific AI instructions, schema,
  synonyms, and verified answers require review and configuration in Power BI
  **Prep data for AI**; instructions are not a security or correctness
  guarantee. Preserve existing Prep data for AI artifacts and retest after any
  changes.
- The Foundry prompt agent `macaw-education-assistant`, version `1`, is
  deployed with the configured model. Its two Fabric IQ tools use the
  published Data Agents and the `macaw-operations-iq` and `macaw-outcomes-iq`
  connections. Both connections use `UserEntraToken` and
  `isSharedToAll: false`; this does not prove the Foundry project or agent has
  no other effective access. Version `1` predates the subject-enrollment
  instructions and has not been updated or retested since the Data Agents
  were republished.
- End-to-end tests under the administrator's identity returned 5,600 students
  through the operations agent and 87,100 results through the outcomes agent.
  One Foundry test correctly declined the unsupported question about Dutch
  subject enrollment; it does not guarantee future answers. Restricted-user
  access, denial, and cross-surface isolation remain unverified. Foundry
  project permissions have not been comprehensively audited.
- Foundry synthetic data and evaluator generation jobs for agent version `1`
  succeeded. The registered dataset is `macaw-education-smoke` version `1.0`
  with 15 generated samples; the registered custom evaluator is
  `macaw-education-quality` version `1`. Their job IDs are in
  `.foundry/agent-metadata.yaml`. Local exports are in `.foundry/datasets/`
  and `.foundry/evaluators/`. The versioned `-questions.jsonl` file contains
  only the questions; the other dataset file preserves the full generated
  output, and `macaw-education-quality-v1.json` contains the registered evaluator.
  No remote evaluation suite has been verified, and no batch evaluation has
  been run.
- Treat all generated questions and evaluator criteria as drafts, not an
  answer key. Many generated `candidate_response` fields say the Fabric tools
  are unavailable; those statements describe generation-time responses, not
  expected answers from the deployed agent. The descriptions request source
  evidence, but no such evidence was saved with the cases. Case 8 assumes a
  future scheduled assessment whose existence is unverified. Cases 14 and 15
  require controlled unavailable and access-denied tool responses; those
  fixtures do not exist yet, and case 15 also lacks a concrete record ID.
  Bind entity-dependent questions to verified records before scoring them.
- The generated evaluator has a `0.5` overall pass threshold and no verified
  hard-fail gate for prohibited profiling or unsupported filters. Its
  grounding and routing criteria require actual tool traces and responses,
  whose mapping into evaluation inputs has not been validated. Matching a
  Fabric agent's response does not establish that the agent itself was correct;
  compare numeric answers with independently verified SQL results. Review
  whether its temporal criterion incorrectly rejects trends within the observed
  snapshot, and require explicit safety and security checks separately.
  The registered version predates subject-enrollment support and must not be
  treated as an evaluator for the updated model without review.
- The structured GraphQL API has not been deployed or verified. The intended
  read-only route is an SQL analytics endpoint source, which supports GraphQL
  queries but not mutations. Use delegated user identity and SSO only after
  separately configuring and validating SQL endpoint row-level security.
  Verify that GraphQL discovers usable keys for every selected object and
  expose only necessary objects and columns. Consumers need GraphQL execution
  permission and appropriate data-source access; API access alone does not
  enforce the campus/department policy. Do not grant workspace Contributor
  access or unprotected OneLake access as a shortcut.
- On the SQL analytics endpoint, `sys.key_constraints` reports no primary
  key metadata for `AnalyticsLearner`, `AnalyticsLearnerDepartment`,
  `AnalyticsSubject`, `AnalyticsAttendance`, or `AnalyticsAssessmentResult`.
  Their candidate key columns are non-nullable. GraphQL documents a key
  requirement, so verify actual schema generation and uniqueness before
  selecting these objects. SQL analytics endpoints support `NOT ENFORCED`
  key constraints, but do not add them without assessing mirroring and schema
  evolution; no GraphQL schema has been tested.
- Verify tenant settings for Azure OpenAI-powered experiences, cross-region
  processing, and storage in the target environment; the requirements can
  depend on the capacity's region. Never change these settings without approval.
  External MCP clients may process data outside Fabric's geographic or
  compliance boundary.
- Direct Lake uses single sign-on by default. Granting consumers underlying
  OneLake access could let them bypass semantic-model RLS. Before sharing,
  evaluate a least-privilege fixed-identity data connection for the model and
  verify that consumers cannot query unprotected source data directly.
- The initial synthetic academic-year calendar is 2026–2027. Autumn and
  spring dates follow government advice for the applicable region; actual
  schools may choose different dates. The loaded observation snapshot is
  2026-11-20; later calendar entries are schedules, not observations.
- Attendance rate is `(Present + Late) / all observed attendance records`.
  Primary assessment outcomes are qualitative; secondary marks use a
  fictional subset of the Dutch 1–10 scale. The generated subject combinations
  are illustrative, not a complete Dutch curriculum.
- The SQL scripts create data only in an empty target, accept the
  `SnapshotDate` SQLCMD variable in `YYYY-MM-DD` form, and refuse a future
  snapshot. Do not rerun them against existing data without inspecting the
  target. Never save access tokens in project files or command arguments.
- The project owner chose pair-specific campus/department access and
  department-student restrictions for enrolment and attendance. The staged
  test mapping uses individual user principal names, not Entra groups.
  Effective permissions and restricted-user behavior remain unverified. Do not
  share or advertise an external endpoint as securely isolated before the
  relevant access tests pass.

## Pending acceptance gates

1. Complete the approved subject-level enrollment integration: update and
   test the Foundry instructions, extend Data Agent validation, and validate
   security propagation with restricted users. Daily attendance is not a
   record of attendance at an individual lesson.
2. Names are populated and mirrored, but are not yet in the semantic model or
   Data Agents. Configure and test access controls before adding them to any
   consumer-facing demo surface.
3. Configure and verify the test identities' effective permissions and model
   role membership in an isolated environment. The staged direct-principal
   records are not a deployed policy; manage role membership in the Power BI
   portal after the relevant source protections are in place.
4. Configure and verify security independently for the operational SQL
   database, mirrored SQL analytics endpoint, semantic model, OneLake,
   Data Agents, GraphQL, and Foundry. Test allowed and denied pairs, overlapping
   departments, users without a grant, and attempts to bypass each surface.
   Validate with non-admin users and least-privilege permissions.
5. Before sharing GraphQL, confirm its source connection uses SSO, its schema
   contains only approved read-only objects and fields, mutations are absent,
   and restricted-user results agree with the secured SQL analytics endpoint.
   Verify the registered application's delegated `GraphQLApi.Execute.All`
   scope and the API and data-source permissions.
6. Before using the generated questions, establish their source evidence,
   concrete entities, fault fixtures, and independent expected results. Review
   the evaluator's threshold, trace inputs, temporal scope, and safety
   criteria. Register or verify any suite before claiming one exists. Run a
   batch evaluation only after the project owner approves it.
7. Preserve the validated SQL and four-source enrichment products; configure
   an approved external failure notification if required. Add Gold-backed
   agent-ready models and delegated agent integration only after independent
   security validation. Do not share new surfaces until their tests pass.
8. Confirm persistent PostgreSQL source selection, mirror freshness and
   independent security; account for the additional SQL tables and future
   schema additions. Administrator execution does not validate a separate
   pipeline identity or restricted users.

## Suggested Prep data for AI review

The following are recommendations for review in the Power BI UI, not changes
already applied or security controls:

- Explain the snapshot date, attendance numerator and denominator, qualitative
  primary outcomes, overlapping subject and department membership, supported
  individual-subject enrollment, and unsupported individual-subject attendance.
- Include only business-relevant AI-visible fields and their measure
  dependencies; do not expose technical security tables merely to improve
  natural-language answers.
- Consider verified answers for students by campus; attendance rate and its
  underlying counts by campus; assessment results by subject; average
  secondary mark by campus and track; and qualitative outcomes by subject.
  Verify each candidate against SQL and with restricted identities before use.

## References

- [Dutch education system overview](https://eurydice.eacea.ec.europa.eu/eurypedia/netherlands/overview)
- [Primary education subjects](https://www.government.nl/themes/education/primary-education/subjects-and-attainment-targets-in-primary-education)
- [VMBO programmes](https://www.government.nl/themes/education/secondary-education/different-types-of-secondary-education/pre-vocational-secondary-education-vmbo)
- [HAVO and VWO programmes](https://www.government.nl/themes/education/secondary-education/different-types-of-secondary-education/senior-general-secondary-education-havo-and-pre-university-education-vwo)
- [Dutch school holidays](https://www.government.nl/themes/education/school-holidays)
- [School-holiday regions by municipality](https://www.rijksoverheid.nl/themas/onderwijs/schoolvakanties/regios-schoolvakantie)
- [2026–2027 school-holiday dates](https://www.rijksoverheid.nl/themas/onderwijs/schoolvakanties/overzicht-schoolvakanties-per-schooljaar/overzicht-schoolvakanties-2026-2027)
- [Fabric SQL Database mirroring](https://learn.microsoft.com/en-us/fabric/database/sql/mirroring-overview)
- [Security of mirrored SQL data](https://learn.microsoft.com/en-us/fabric/database/sql/mirroring-secure)
- [Fabric Data Agent Python SDK](https://learn.microsoft.com/en-us/fabric/data-science/fabric-data-agent-sdk)
- [Data Agent datasource few-shot limitation](https://learn.microsoft.com/en-us/rest/api/fabric/dataagent/staging/create-datasource-fewshot)
- [Semantic model best practices for Data Agents](https://learn.microsoft.com/en-us/fabric/data-science/semantic-model-best-practices)
- [Prepare data for AI](https://learn.microsoft.com/en-us/power-bi/create-reports/copilot-prepare-data-ai)
- [Fabric GraphQL authentication and permissions](https://learn.microsoft.com/en-us/fabric/data-engineering/connect-apps-api-graphql)
- [Fabric GraphQL limitations](https://learn.microsoft.com/en-us/fabric/data-engineering/api-graphql-limits)
- [SQL analytics endpoint key constraints](https://learn.microsoft.com/en-us/fabric/data-warehouse/table-constraints)
- [SQL analytics endpoint row-level security](https://learn.microsoft.com/en-us/fabric/data-warehouse/row-level-security)
- [Fabric API for GraphQL definition](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/graphql-api-definition)
- [Foundry Fabric IQ integration](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/tools/fabric-iq)
