SET NOCOUNT ON;

IF (SELECT COUNT(*) FROM dbo.AnalyticsLearner) <> (SELECT COUNT(*) FROM dbo.Enrollment)
    THROW 50000, 'The learner snapshot does not match the enrollment count.', 1;
IF (SELECT COUNT(*) FROM dbo.AnalyticsAttendance) <> (SELECT COUNT(*) FROM dbo.Attendance)
    THROW 50000, 'The analytical attendance count differs from the source.', 1;
IF (SELECT COUNT(*) FROM dbo.AnalyticsAssessmentResult) <> (SELECT COUNT(*) FROM dbo.AssessmentResult)
    THROW 50000, 'The analytical assessment count differs from the source.', 1;
IF EXISTS (
    SELECT learner.EnrollmentKey, s.DepartmentKey, learner.CampusKey * 100 + s.DepartmentKey
    FROM dbo.AnalyticsLearner AS learner
    INNER JOIN dbo.EnrollmentSubject AS es ON es.EnrollmentKey = learner.EnrollmentKey
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    INNER JOIN dbo.Subject AS s ON s.SubjectKey = ta.SubjectKey
    EXCEPT
    SELECT EnrollmentKey, DepartmentKey, CampusDepartmentKey
    FROM dbo.AnalyticsLearnerDepartment
)
    THROW 50000, 'A learner-department membership is missing.', 1;
IF EXISTS (
    SELECT EnrollmentKey, DepartmentKey, CampusDepartmentKey
    FROM dbo.AnalyticsLearnerDepartment
    EXCEPT
    SELECT learner.EnrollmentKey, s.DepartmentKey, learner.CampusKey * 100 + s.DepartmentKey
    FROM dbo.AnalyticsLearner AS learner
    INNER JOIN dbo.EnrollmentSubject AS es ON es.EnrollmentKey = learner.EnrollmentKey
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    INNER JOIN dbo.Subject AS s ON s.SubjectKey = ta.SubjectKey
)
    THROW 50000, 'A learner-department membership has no corresponding subject enrollment.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.AnalyticsAssessmentResult AS r
    INNER JOIN dbo.AnalyticsLearner AS learner ON learner.EnrollmentKey = r.EnrollmentKey
    INNER JOIN dbo.AnalyticsSubject AS subject ON subject.SubjectKey = r.SubjectKey
    LEFT JOIN dbo.AnalyticsLearnerDepartment AS membership
        ON membership.EnrollmentKey = r.EnrollmentKey AND membership.DepartmentKey = r.DepartmentKey
    WHERE r.DepartmentKey <> subject.DepartmentKey
       OR r.CampusDepartmentKey <> learner.CampusKey * 100 + subject.DepartmentKey
       OR membership.LearnerDepartmentKey IS NULL
)
    THROW 50000, 'An assessment result has an inconsistent campus-department membership.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.AnalyticsAttendance AS a
    INNER JOIN dbo.DateDimension AS d ON d.DateKey = a.DateKey
    INNER JOIN dbo.AnalyticsLearner AS learner ON learner.EnrollmentKey = a.EnrollmentKey
    WHERE d.CalendarDate > learner.SnapshotDate
)
    THROW 50000, 'Analytical attendance contains a future observation.', 1;

SELECT 'Learners' AS Metric, COUNT_BIG(*) AS Value FROM dbo.AnalyticsLearner
UNION ALL SELECT 'Learner-department memberships', COUNT_BIG(*) FROM dbo.AnalyticsLearnerDepartment
UNION ALL SELECT 'Subjects', COUNT_BIG(*) FROM dbo.AnalyticsSubject
UNION ALL SELECT 'Attendance records', COUNT_BIG(*) FROM dbo.AnalyticsAttendance
UNION ALL SELECT 'Assessment results', COUNT_BIG(*) FROM dbo.AnalyticsAssessmentResult
UNION ALL SELECT 'Configured access grants', COUNT_BIG(*) FROM dbo.SecurityAccessGrant;
