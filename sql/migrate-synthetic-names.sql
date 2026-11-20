SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.SyntheticPersonName', N'IF') IS NULL
    THROW 50000, 'Create the synthetic name generator before running this migration.', 1;
IF OBJECT_ID(N'dbo.Student', N'U') IS NULL
   OR OBJECT_ID(N'dbo.Teacher', N'U') IS NULL
   OR OBJECT_ID(N'dbo.Enrollment', N'U') IS NULL
   OR OBJECT_ID(N'dbo.AnalyticsLearner', N'U') IS NULL
    THROW 50000, 'The operational and analytical snapshot tables are required.', 1;
IF COL_LENGTH(N'dbo.Student', N'FirstName') IS NOT NULL
   OR COL_LENGTH(N'dbo.Student', N'LastName') IS NOT NULL
   OR COL_LENGTH(N'dbo.Teacher', N'FirstName') IS NOT NULL
   OR COL_LENGTH(N'dbo.Teacher', N'LastName') IS NOT NULL
   OR COL_LENGTH(N'dbo.AnalyticsLearner', N'FirstName') IS NOT NULL
   OR COL_LENGTH(N'dbo.AnalyticsLearner', N'LastName') IS NOT NULL
    THROW 50000, 'Name columns already exist; inspect the target before migrating.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Student)
   OR NOT EXISTS (SELECT 1 FROM dbo.Teacher)
   OR EXISTS (SELECT 1 FROM dbo.Student WHERE StudentKey <= 0)
   OR EXISTS (SELECT 1 FROM dbo.Teacher WHERE TeacherKey <= 0)
    THROW 50000, 'The snapshot must contain students and teachers with positive keys.', 1;
IF (SELECT COUNT_BIG(*) FROM dbo.AnalyticsLearner) <> (SELECT COUNT_BIG(*) FROM dbo.Enrollment)
   OR EXISTS (
       SELECT 1
       FROM dbo.Enrollment AS e
       INNER JOIN dbo.Student AS s ON s.StudentKey = e.StudentKey
       LEFT JOIN dbo.AnalyticsLearner AS a ON a.EnrollmentKey = e.EnrollmentKey
       WHERE a.EnrollmentKey IS NULL OR a.StudentCode <> s.StudentCode
   )
    THROW 50000, 'The learner snapshot does not match the operational enrollments.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    SELECT StudentKey, StudentCode INTO #BeforeStudent FROM dbo.Student;
    SELECT TeacherKey, TeacherCode, SchoolUnitKey, DepartmentKey, TeacherSequence
    INTO #BeforeTeacher FROM dbo.Teacher;
    SELECT EnrollmentKey, StudentKey, ClassSectionKey, TrackKey, ProfileKey
    INTO #BeforeEnrollment FROM dbo.Enrollment;
    SELECT EnrollmentKey, StudentCode INTO #BeforeLearner FROM dbo.AnalyticsLearner;

    ALTER TABLE dbo.Student ADD FirstName nvarchar(80) NULL, LastName nvarchar(80) NULL;
    ALTER TABLE dbo.Teacher ADD FirstName nvarchar(80) NULL, LastName nvarchar(80) NULL;
    ALTER TABLE dbo.AnalyticsLearner ADD FirstName nvarchar(80) NULL, LastName nvarchar(80) NULL;

    EXEC sys.sp_executesql N'
        UPDATE s
        SET FirstName = person.FirstName, LastName = person.LastName
        FROM dbo.Student AS s
        CROSS APPLY dbo.SyntheticPersonName(s.StudentKey, ''S'') AS person;

        UPDATE t
        SET FirstName = person.FirstName, LastName = person.LastName
        FROM dbo.Teacher AS t
        CROSS APPLY dbo.SyntheticPersonName(t.TeacherKey, ''T'') AS person;

        UPDATE a
        SET FirstName = s.FirstName, LastName = s.LastName
        FROM dbo.AnalyticsLearner AS a
        INNER JOIN dbo.Enrollment AS e ON e.EnrollmentKey = a.EnrollmentKey
        INNER JOIN dbo.Student AS s ON s.StudentKey = e.StudentKey;
    ';

    ALTER TABLE dbo.Student ALTER COLUMN FirstName nvarchar(80) NOT NULL;
    ALTER TABLE dbo.Student ALTER COLUMN LastName nvarchar(80) NOT NULL;
    ALTER TABLE dbo.Teacher ALTER COLUMN FirstName nvarchar(80) NOT NULL;
    ALTER TABLE dbo.Teacher ALTER COLUMN LastName nvarchar(80) NOT NULL;
    ALTER TABLE dbo.AnalyticsLearner ALTER COLUMN FirstName nvarchar(80) NOT NULL;
    ALTER TABLE dbo.AnalyticsLearner ALTER COLUMN LastName nvarchar(80) NOT NULL;

    IF EXISTS (SELECT StudentKey, StudentCode FROM #BeforeStudent EXCEPT SELECT StudentKey, StudentCode FROM dbo.Student)
       OR EXISTS (SELECT StudentKey, StudentCode FROM dbo.Student EXCEPT SELECT StudentKey, StudentCode FROM #BeforeStudent)
       OR EXISTS (
           SELECT TeacherKey, TeacherCode, SchoolUnitKey, DepartmentKey, TeacherSequence FROM #BeforeTeacher
           EXCEPT
           SELECT TeacherKey, TeacherCode, SchoolUnitKey, DepartmentKey, TeacherSequence FROM dbo.Teacher
       )
       OR EXISTS (
           SELECT TeacherKey, TeacherCode, SchoolUnitKey, DepartmentKey, TeacherSequence FROM dbo.Teacher
           EXCEPT
           SELECT TeacherKey, TeacherCode, SchoolUnitKey, DepartmentKey, TeacherSequence FROM #BeforeTeacher
       )
       OR EXISTS (
           SELECT EnrollmentKey, StudentKey, ClassSectionKey, TrackKey, ProfileKey FROM #BeforeEnrollment
           EXCEPT
           SELECT EnrollmentKey, StudentKey, ClassSectionKey, TrackKey, ProfileKey FROM dbo.Enrollment
       )
       OR EXISTS (
           SELECT EnrollmentKey, StudentKey, ClassSectionKey, TrackKey, ProfileKey FROM dbo.Enrollment
           EXCEPT
           SELECT EnrollmentKey, StudentKey, ClassSectionKey, TrackKey, ProfileKey FROM #BeforeEnrollment
       )
       OR EXISTS (SELECT EnrollmentKey, StudentCode FROM #BeforeLearner EXCEPT SELECT EnrollmentKey, StudentCode FROM dbo.AnalyticsLearner)
       OR EXISTS (SELECT EnrollmentKey, StudentCode FROM dbo.AnalyticsLearner EXCEPT SELECT EnrollmentKey, StudentCode FROM #BeforeLearner)
        THROW 50000, 'Keys, codes, or enrollment relationships changed during the migration.', 1;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
