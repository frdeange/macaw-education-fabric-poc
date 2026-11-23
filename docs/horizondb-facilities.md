# HorizonDB synthetic facilities source

The HorizonDB source is a proposed synthetic facilities dimension, separate
from the operational SQL database. The source scripts live in
[`horizondb/`](../horizondb/). They define PostgreSQL base types, primary keys,
simple checks, and one foreign key between the two source tables. No extension
or custom type is used. Whether the exact schema is eligible for mirroring
must still be checked in the target preview environment.

## Synthetic scenario

- Five campus keys (`1` through `5`) match the stable fictional SQL seed keys.
- Each campus has 56 class rooms, one for each existing class section, with a
  fictional capacity of 24. The stable section mapping is
  `(campus_key - 1) * 56 + section_number`.
- Each campus has four additional illustrative specialist spaces: a science
  lab, creative arts studio, sports hall, and flexible room.
- Five room closures are planned for 3 December 2026 from 09:00 to 11:00
  Europe/Amsterdam time. They are labeled synthetic planned maintenance, not
  observed closures.

These are proof-of-concept assumptions, not an inventory or capacity claim
about a real school. The `class_section_key` is a cross-source reference; a
PostgreSQL foreign key cannot enforce referential integrity against the Fabric
SQL Database. Validate the keys against the SQL mirror before using the data.
Room availability must not be joined to student-day attendance as though it
were evidence that a lesson occurred.

## Safe setup sequence

1. In the approved isolated Fabric workspace, create the HorizonDB item through
   **+ New item > HorizonDB database (preview)**. The current public preview
   does not establish a supported REST creation route.
2. Use the database creator identity and the connection settings shown by the
   item. Current preview documentation says only the creator can connect;
   item sharing and workspace roles do not grant PostgreSQL access to other
   users, groups, service principals, or managed identities.
3. Inspect the engine and current mirroring eligibility in the target
   environment. Apply `horizondb/schema.sql`, then `horizondb/seed.sql` only
   to an empty target.
4. Run `horizondb/validate.sql` and compare class-section keys with the
   allowlisted SQL mirror extract. These checks do not prove that tables have
   mirrored or that their copy is current.
5. Wait for the displayed initial-copy status before any downstream
   comparison. Mirroring is asynchronous and has no published numeric
   freshness guarantee.

The seed inserts a one-row marker first and uses primary keys to refuse
duplicate seeding. Do not drop or truncate tables to retry. Inspect a failed
target and resolve it deliberately. Preserve an independent export before any
irreversible deletion.

No HorizonDB item was created or connected to for this change. The schema,
table-type eligibility, authentication, mirror state, security, and live
row-count comparisons remain unverified. Do not treat the presence of a
HorizonDB item or a SQL analytics endpoint as proof of those checks.

## Official preview boundaries

- [HorizonDB limitations](https://learn.microsoft.com/en-us/fabric/database/horizondb/limitations)
- [HorizonDB mirroring limitations](https://learn.microsoft.com/en-us/fabric/database/horizondb/mirroring-limitations)

The public preview can change. Recheck availability, supported types and DDL,
permissions, region, networking, costs, and mirroring status before setup.
Operational PostgreSQL access and mirrored analytical access are distinct
security surfaces; configure and validate each separately before sharing data.
