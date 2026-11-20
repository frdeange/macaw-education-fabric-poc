# Security test access matrix

The project owner authorized the use of seven existing generic test accounts
and delegated the choice of campus-department pairs. The matrix below is for
testing, not a production access policy.

**Status: staged, not enforced or ready for sharing.** Nine pair records for
five accounts were stored in `SecurityAccessGrant`. The other two accounts
have no pair records. The SQL database and SQL analytics endpoint contain the
same nine records, and an administrator query of the semantic model returned
nine records for five principals. This does not establish row-level security
or grant the accounts permission to use any surface.

The scenario-to-identity mapping is stored outside this public repository at
`%LOCALAPPDATA%\MacawEducation\security-test-mapping.json`. It contains no
credentials and its local file permissions are restricted to the current
Windows user. Keep operational identities out of source control. The mapping
uses individual Microsoft Entra user principal names, not group membership.
If an account's principal name changes, reconcile the private mapping and SQL
records before testing again.

## Assigned pairs

| Scenario | Campus-department pairs | Purpose |
| --- | --- | --- |
| A | Amsterdam / Languages; Eindhoven / Science and Technology | Two campuses and departments; reject crossed pairs. |
| B | Amsterdam / Mathematics; Rotterdam / Languages; Groningen / Physical Education | Multiple pairs and overlap with other scenarios. |
| C | Utrecht / Social and Environmental Studies; Utrecht / Creative Arts | Multiple departments at one campus; deduplicate learners. |
| D | None | No-grant control with a listed Power BI service plan. |
| E | Rotterdam / Science and Technology | Additional single-pair scenario. |
| F | Groningen / Mathematics | Additional single-pair scenario. |
| G | None | Additional no-grant control. |

Campus names above abbreviate the corresponding fictional `Macaw ... Campus`
names. A grant is a **pair**, not the cross-product of its campuses and
departments. For example, A is not granted Amsterdam / Science and Technology
or Eindhoven / Languages. B is not granted Amsterdam / Languages.

A learner can take subjects in more than one department. Under the intended
policy, a user can see a learner and that learner's student-day attendance
when at least one authorized pair applies; this does not authorize
subject-enrollment or assessment rows from an unauthorized department.
Attendance is not recorded by lesson.

## Independent expected results

These are administrator-side SQL calculations for the 20 November 2026
snapshot, using the matrix above. They are an oracle for later tests, not
results obtained by signing in as the test accounts. Learners are distinct
across the authorized pairs.

| Scenario | Learners | Attendance records | Subject enrollments | Assessment results | Teachers |
| --- | ---: | ---: | ---: | ---: | ---: |
| A | 1,970 | 123,800 | 3,500 | 7,000 | 16 |
| B | 3,360 | 207,200 | 4,450 | 8,900 | 24 |
| C | 1,120 | 61,600 | 2,970 | 5,940 | 16 |
| D | 0 | 0 | 0 | 0 | 0 |
| E | 850 | 46,750 | 1,290 | 2,580 | 8 |
| F | 1,120 | 72,800 | 1,120 | 2,240 | 8 |
| G | 0 | 0 | 0 | 0 | 0 |

Teacher counts come from the operational SQL tables. The proposed analytical
teacher directory and its model table have not been deployed. A no-grant user
may receive an authorization error rather than a zero-row response; verify
the behavior of each surface.

## Remaining controls and tests

- The grant table is configuration data, not a security policy. No test
  account was given workspace, model, SQL, OneLake, Data Agent, or Foundry
  access by this change. Semantic-model role membership was not configured or
  verified. Manage role membership in the Power BI portal only after preparing
  an isolated, protected test environment.
- The model currently uses an automatic Azure Data Lake Storage connection.
  Evaluate a least-privilege fixed identity before granting model access, and
  confirm that users cannot bypass model security through the source or
  OneLake. Neither SQL Database RLS nor semantic-model RLS automatically
  protects the mirrored SQL endpoint or OneLake.
- The SQL database currently has no enabled security policies. Do not share
  the SQL database, SQL analytics endpoint, or their OneLake data until their
  independent controls and bypass tests pass. `SecurityAccessGrant` itself
  contains operational identity metadata and is mirrored.
- Scenarios A-D had an enabled Power BI service plan listed in the directory;
  none was listed for E-G. Confirm the required licenses, sign-in access,
  MFA, and effective permissions before testing. Do not assume that a listed
  plan proves the account can use every surface.
- With actual non-admin identities, test permitted and denied pairs, the
  crossed-pair cases above, overlapping departments, D's no-grant case, and
  direct access attempts to every exposed surface. Compare results with the
  SQL oracle; do not treat administrator impersonation as an end-to-end test.
- A read-only administrator impersonation attempt for A returned an
  entity-not-found-or-permission error before any rows were returned. This
  is not a test of row-level isolation. Data Agents remain unshared, and
  GraphQL has not been deployed.
