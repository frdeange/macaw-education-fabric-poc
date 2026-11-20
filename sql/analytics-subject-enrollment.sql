SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.AnalyticsSubjectEnrollment', N'U') IS NOT NULL
    THROW 50000, 'The subject enrollment snapshot already exists; inspect it before continuing.', 1;
IF EXISTS (SELECT 1 FROM dbo.Department WHERE DepartmentKey NOT BETWEEN 1 AND 99)
    THROW 50000, 'Campus-department keys require department keys between 1 and 99.', 1;
IF EXISTS (
    SELECT es.EnrollmentKey, ta.SubjectKey
    FROM dbo.EnrollmentSubject AS es
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    GROUP BY es.EnrollmentKey, ta.SubjectKey
    HAVING COUNT(*) > 1
)
    THROW 50000, 'A student has more than one assignment for the same subject.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.EnrollmentSubject AS es
    INNER JOIN dbo.Enrollment AS e ON e.EnrollmentKey = es.EnrollmentKey
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    INNER JOIN dbo.Subject AS s ON s.SubjectKey = ta.SubjectKey
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
    INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
    LEFT JOIN dbo.AnalyticsLearner AS learner ON learner.EnrollmentKey = es.EnrollmentKey
    LEFT JOIN dbo.AnalyticsSubject AS subject ON subject.SubjectKey = ta.SubjectKey
    LEFT JOIN dbo.AnalyticsLearnerDepartment AS membership
        ON membership.EnrollmentKey = es.EnrollmentKey AND membership.DepartmentKey = s.DepartmentKey
    WHERE learner.EnrollmentKey IS NULL
       OR subject.SubjectKey IS NULL
       OR membership.LearnerDepartmentKey IS NULL
       OR e.ClassSectionKey <> ta.ClassSectionKey
       OR learner.ClassSectionKey <> e.ClassSectionKey
       OR learner.CampusKey <> u.CampusKey
       OR subject.DepartmentKey <> s.DepartmentKey
       OR membership.CampusDepartmentKey <> learner.CampusKey * 100 + s.DepartmentKey
)
    THROW 50000, 'Source enrollment and analytical campus, class, subject, or department data differ.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    CREATE TABLE dbo.AnalyticsSubjectEnrollment (
        EnrollmentKey int NOT NULL REFERENCES dbo.AnalyticsLearner(EnrollmentKey),
        SubjectKey int NOT NULL REFERENCES dbo.AnalyticsSubject(SubjectKey),
        DepartmentKey int NOT NULL REFERENCES dbo.Department(DepartmentKey),
        CampusDepartmentKey int NOT NULL,
        CONSTRAINT PK_AnalyticsSubjectEnrollment PRIMARY KEY (EnrollmentKey, SubjectKey)
    );

    INSERT dbo.AnalyticsSubjectEnrollment (
        EnrollmentKey, SubjectKey, DepartmentKey, CampusDepartmentKey
    )
    SELECT es.EnrollmentKey, ta.SubjectKey, subject.DepartmentKey,
           learner.CampusKey * 100 + subject.DepartmentKey
    FROM dbo.EnrollmentSubject AS es
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    INNER JOIN dbo.AnalyticsSubject AS subject ON subject.SubjectKey = ta.SubjectKey
    INNER JOIN dbo.AnalyticsLearner AS learner ON learner.EnrollmentKey = es.EnrollmentKey;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
