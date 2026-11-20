SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.AnalyticsSubjectEnrollment', N'U') IS NULL
    THROW 50000, 'The subject enrollment snapshot does not exist.', 1;
IF (SELECT COUNT_BIG(*) FROM dbo.AnalyticsSubjectEnrollment) <>
   (SELECT COUNT_BIG(*) FROM dbo.EnrollmentSubject)
    THROW 50000, 'The subject enrollment count differs from the source.', 1;
IF EXISTS (
    SELECT es.EnrollmentKey, ta.SubjectKey, subject.DepartmentKey,
           unit.CampusKey * 100 + subject.DepartmentKey
    FROM dbo.EnrollmentSubject AS es
    INNER JOIN dbo.Enrollment AS e ON e.EnrollmentKey = es.EnrollmentKey
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    INNER JOIN dbo.Subject AS subject ON subject.SubjectKey = ta.SubjectKey
    INNER JOIN dbo.ClassSection AS class ON class.ClassSectionKey = e.ClassSectionKey
    INNER JOIN dbo.SchoolUnit AS unit ON unit.SchoolUnitKey = class.SchoolUnitKey
    EXCEPT
    SELECT EnrollmentKey, SubjectKey, DepartmentKey, CampusDepartmentKey
    FROM dbo.AnalyticsSubjectEnrollment
)
    THROW 50000, 'The subject enrollment snapshot is missing source rows.', 1;
IF EXISTS (
    SELECT EnrollmentKey, SubjectKey, DepartmentKey, CampusDepartmentKey
    FROM dbo.AnalyticsSubjectEnrollment
    EXCEPT
    SELECT es.EnrollmentKey, ta.SubjectKey, subject.DepartmentKey,
           unit.CampusKey * 100 + subject.DepartmentKey
    FROM dbo.EnrollmentSubject AS es
    INNER JOIN dbo.Enrollment AS e ON e.EnrollmentKey = es.EnrollmentKey
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    INNER JOIN dbo.Subject AS subject ON subject.SubjectKey = ta.SubjectKey
    INNER JOIN dbo.ClassSection AS class ON class.ClassSectionKey = e.ClassSectionKey
    INNER JOIN dbo.SchoolUnit AS unit ON unit.SchoolUnitKey = class.SchoolUnitKey
)
    THROW 50000, 'The subject enrollment snapshot contains rows absent from the source.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.EnrollmentSubject AS es
    INNER JOIN dbo.Enrollment AS e ON e.EnrollmentKey = es.EnrollmentKey
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    INNER JOIN dbo.AnalyticsLearner AS learner ON learner.EnrollmentKey = es.EnrollmentKey
    INNER JOIN dbo.Subject AS subject ON subject.SubjectKey = ta.SubjectKey
    INNER JOIN dbo.AnalyticsSubject AS analyticalSubject ON analyticalSubject.SubjectKey = ta.SubjectKey
    WHERE e.ClassSectionKey <> ta.ClassSectionKey
       OR learner.ClassSectionKey <> e.ClassSectionKey
       OR analyticalSubject.SubjectName <> subject.SubjectName
       OR analyticalSubject.DepartmentKey <> subject.DepartmentKey
)
    THROW 50000, 'A subject enrollment differs from the source class or subject.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.AnalyticsSubjectEnrollment AS enrollment
    INNER JOIN dbo.AnalyticsLearner AS learner ON learner.EnrollmentKey = enrollment.EnrollmentKey
    INNER JOIN dbo.AnalyticsSubject AS subject ON subject.SubjectKey = enrollment.SubjectKey
    LEFT JOIN dbo.AnalyticsLearnerDepartment AS membership
        ON membership.EnrollmentKey = enrollment.EnrollmentKey
       AND membership.DepartmentKey = enrollment.DepartmentKey
    WHERE enrollment.DepartmentKey <> subject.DepartmentKey
       OR enrollment.CampusDepartmentKey <> learner.CampusKey * 100 + subject.DepartmentKey
       OR membership.LearnerDepartmentKey IS NULL
       OR membership.CampusDepartmentKey <> enrollment.CampusDepartmentKey
)
    THROW 50000, 'A subject enrollment has an inconsistent campus-department membership.', 1;

SELECT COUNT_BIG(*) AS SubjectEnrollments,
       COUNT(DISTINCT EnrollmentKey) AS Students,
       COUNT(DISTINCT SubjectKey) AS Subjects
FROM dbo.AnalyticsSubjectEnrollment;

SELECT learner.CampusName, COUNT(DISTINCT enrollment.EnrollmentKey) AS StudentsTakingDutch
FROM dbo.AnalyticsSubjectEnrollment AS enrollment
INNER JOIN dbo.AnalyticsLearner AS learner ON learner.EnrollmentKey = enrollment.EnrollmentKey
INNER JOIN dbo.AnalyticsSubject AS subject ON subject.SubjectKey = enrollment.SubjectKey
WHERE subject.SubjectName = N'Dutch'
GROUP BY learner.CampusName
ORDER BY learner.CampusName;
