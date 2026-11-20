SET NOCOUNT ON;

IF EXISTS (
    SELECT 1
    FROM dbo.Student AS s
    OUTER APPLY dbo.SyntheticPersonName(s.StudentKey, 'S') AS person
    WHERE person.FirstName IS NULL OR person.LastName IS NULL
       OR LEN(LTRIM(RTRIM(s.FirstName))) = 0 OR LEN(LTRIM(RTRIM(s.LastName))) = 0
       OR CONVERT(varbinary(160), s.FirstName) <> CONVERT(varbinary(160), person.FirstName)
       OR CONVERT(varbinary(160), s.LastName) <> CONVERT(varbinary(160), person.LastName)
)
    THROW 50000, 'Student names are missing or differ from the deterministic generator.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.Teacher AS t
    OUTER APPLY dbo.SyntheticPersonName(t.TeacherKey, 'T') AS person
    WHERE person.FirstName IS NULL OR person.LastName IS NULL
       OR LEN(LTRIM(RTRIM(t.FirstName))) = 0 OR LEN(LTRIM(RTRIM(t.LastName))) = 0
       OR CONVERT(varbinary(160), t.FirstName) <> CONVERT(varbinary(160), person.FirstName)
       OR CONVERT(varbinary(160), t.LastName) <> CONVERT(varbinary(160), person.LastName)
)
    THROW 50000, 'Teacher names are missing or differ from the deterministic generator.', 1;
IF (SELECT COUNT_BIG(*) FROM dbo.AnalyticsLearner) <> (SELECT COUNT_BIG(*) FROM dbo.Enrollment)
   OR EXISTS (
       SELECT 1
       FROM dbo.Enrollment AS e
       INNER JOIN dbo.Student AS s ON s.StudentKey = e.StudentKey
       LEFT JOIN dbo.AnalyticsLearner AS a ON a.EnrollmentKey = e.EnrollmentKey
       WHERE a.EnrollmentKey IS NULL OR a.StudentCode <> s.StudentCode
          OR CONVERT(varbinary(160), a.FirstName) <> CONVERT(varbinary(160), s.FirstName)
          OR CONVERT(varbinary(160), a.LastName) <> CONVERT(varbinary(160), s.LastName)
   )
    THROW 50000, 'Analytical learner names do not match the operational students.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Student WHERE FirstName COLLATE Latin1_General_100_BIN2 = N'Zoë')
   OR NOT EXISTS (SELECT 1 FROM dbo.Student WHERE LastName COLLATE Latin1_General_100_BIN2 = N'van der Meer')
   OR NOT EXISTS (SELECT 1 FROM dbo.Teacher WHERE LastName COLLATE Latin1_General_100_BIN2 = N'Öztürk')
    THROW 50000, 'The snapshot must retain Unicode names and compound surnames.', 1;

SELECT 'Students with names' AS Metric, COUNT_BIG(*) AS Value FROM dbo.Student
UNION ALL SELECT 'Teachers with names', COUNT_BIG(*) FROM dbo.Teacher
UNION ALL SELECT 'Analytical learners with names', COUNT_BIG(*) FROM dbo.AnalyticsLearner
UNION ALL SELECT 'Distinct student first and last name pairs', COUNT_BIG(*)
    FROM (SELECT FirstName, LastName FROM dbo.Student GROUP BY FirstName, LastName) AS names;
