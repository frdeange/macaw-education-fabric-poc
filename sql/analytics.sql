SET NOCOUNT ON;
SET XACT_ABORT ON;

IF (SELECT COUNT(*) FROM dbo.LoadMetadata) <> 1
    THROW 50000, 'Load and validate the synthetic snapshot before creating analytics tables.', 1;
IF EXISTS (
    SELECT 1 FROM sys.tables
    WHERE schema_id = SCHEMA_ID(N'dbo')
      AND name IN (
          N'AnalyticsLearner', N'AnalyticsLearnerDepartment', N'AnalyticsSubject',
          N'AnalyticsAttendance', N'AnalyticsAssessmentResult', N'SecurityAccessGrant'
      )
)
    THROW 50000, 'An analytics target table already exists; inspect the database before continuing.', 1;

BEGIN TRANSACTION;

CREATE TABLE dbo.AnalyticsLearner (
    EnrollmentKey int NOT NULL PRIMARY KEY REFERENCES dbo.Enrollment(EnrollmentKey),
    StudentCode varchar(12) NOT NULL,
    FirstName nvarchar(80) NOT NULL,
    LastName nvarchar(80) NOT NULL,
    CampusKey int NOT NULL,
    CampusName nvarchar(100) NOT NULL,
    City nvarchar(50) NOT NULL,
    HolidayRegion varchar(10) NOT NULL,
    SchoolUnitName nvarchar(120) NOT NULL,
    EducationStage varchar(10) NOT NULL,
    AcademicYearName varchar(9) NOT NULL,
    YearLevelName nvarchar(40) NOT NULL,
    LevelNumber int NOT NULL,
    ClassSectionKey int NOT NULL,
    SectionCode char(1) NOT NULL,
    TrackName varchar(10) NULL,
    ProfileName nvarchar(80) NULL,
    SnapshotDate date NOT NULL
);

CREATE TABLE dbo.AnalyticsLearnerDepartment (
    LearnerDepartmentKey int NOT NULL PRIMARY KEY,
    EnrollmentKey int NOT NULL REFERENCES dbo.AnalyticsLearner(EnrollmentKey),
    DepartmentKey int NOT NULL REFERENCES dbo.Department(DepartmentKey),
    DepartmentName nvarchar(80) NOT NULL,
    CampusDepartmentKey int NOT NULL,
    CONSTRAINT UQ_AnalyticsLearnerDepartment UNIQUE (EnrollmentKey, DepartmentKey)
);

CREATE TABLE dbo.AnalyticsSubject (
    SubjectKey int NOT NULL PRIMARY KEY REFERENCES dbo.Subject(SubjectKey),
    SubjectName nvarchar(80) NOT NULL,
    DepartmentKey int NOT NULL REFERENCES dbo.Department(DepartmentKey)
);

CREATE TABLE dbo.AnalyticsAttendance (
    EnrollmentKey int NOT NULL REFERENCES dbo.AnalyticsLearner(EnrollmentKey),
    DateKey int NOT NULL REFERENCES dbo.DateDimension(DateKey),
    AttendanceStatus varchar(20) NOT NULL,
    CONSTRAINT PK_AnalyticsAttendance PRIMARY KEY (EnrollmentKey, DateKey)
);

CREATE TABLE dbo.AnalyticsAssessmentResult (
    AssessmentKey int NOT NULL REFERENCES dbo.Assessment(AssessmentKey),
    EnrollmentKey int NOT NULL REFERENCES dbo.AnalyticsLearner(EnrollmentKey),
    SubjectKey int NOT NULL REFERENCES dbo.AnalyticsSubject(SubjectKey),
    DepartmentKey int NOT NULL REFERENCES dbo.Department(DepartmentKey),
    CampusDepartmentKey int NOT NULL,
    DateKey int NOT NULL REFERENCES dbo.DateDimension(DateKey),
    Mark decimal(3, 1) NULL,
    QualitativeOutcome varchar(20) NULL,
    CONSTRAINT PK_AnalyticsAssessmentResult PRIMARY KEY (AssessmentKey, EnrollmentKey)
);

CREATE TABLE dbo.SecurityAccessGrant (
    PrincipalName nvarchar(255) NOT NULL,
    CampusDepartmentKey int NOT NULL,
    CONSTRAINT PK_SecurityAccessGrant PRIMARY KEY (PrincipalName, CampusDepartmentKey)
);

INSERT dbo.AnalyticsLearner (
    EnrollmentKey, StudentCode, FirstName, LastName, CampusKey, CampusName, City, HolidayRegion,
    SchoolUnitName, EducationStage, AcademicYearName, YearLevelName, LevelNumber,
    ClassSectionKey, SectionCode, TrackName, ProfileName, SnapshotDate
)
SELECT e.EnrollmentKey, s.StudentCode, s.FirstName, s.LastName, campus.CampusKey, campus.CampusName, campus.City,
       campus.HolidayRegion, u.SchoolUnitName, y.EducationStage, ay.AcademicYearName,
       y.YearLevelName, y.LevelNumber, c.ClassSectionKey, c.SectionCode,
       t.TrackName, p.ProfileName, m.SnapshotDate
FROM dbo.Enrollment AS e
INNER JOIN dbo.Student AS s ON s.StudentKey = e.StudentKey
INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
INNER JOIN dbo.Campus AS campus ON campus.CampusKey = u.CampusKey
INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
INNER JOIN dbo.AcademicYear AS ay ON ay.AcademicYearKey = c.AcademicYearKey
LEFT JOIN dbo.ProgrammeTrack AS t ON t.TrackKey = e.TrackKey
LEFT JOIN dbo.EducationProfile AS p ON p.ProfileKey = e.ProfileKey
INNER JOIN dbo.LoadMetadata AS m ON m.AcademicYearKey = ay.AcademicYearKey;

INSERT dbo.AnalyticsLearnerDepartment (
    LearnerDepartmentKey, EnrollmentKey, DepartmentKey, DepartmentName, CampusDepartmentKey
)
SELECT DISTINCT learner.EnrollmentKey * 10 + d.DepartmentKey, learner.EnrollmentKey,
       d.DepartmentKey, d.DepartmentName, learner.CampusKey * 100 + d.DepartmentKey
FROM dbo.AnalyticsLearner AS learner
INNER JOIN dbo.EnrollmentSubject AS es ON es.EnrollmentKey = learner.EnrollmentKey
INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
INNER JOIN dbo.Subject AS s ON s.SubjectKey = ta.SubjectKey
INNER JOIN dbo.Department AS d ON d.DepartmentKey = s.DepartmentKey;

INSERT dbo.AnalyticsSubject (SubjectKey, SubjectName, DepartmentKey)
SELECT SubjectKey, SubjectName, DepartmentKey
FROM dbo.Subject;

INSERT dbo.AnalyticsAttendance (EnrollmentKey, DateKey, AttendanceStatus)
SELECT a.EnrollmentKey, sc.DateKey, a.AttendanceStatus
FROM dbo.Attendance AS a
INNER JOIN dbo.SchoolCalendar AS sc ON sc.SchoolCalendarKey = a.SchoolCalendarKey;

INSERT dbo.AnalyticsAssessmentResult (
    AssessmentKey, EnrollmentKey, SubjectKey, DepartmentKey,
    CampusDepartmentKey, DateKey, Mark, QualitativeOutcome
)
SELECT r.AssessmentKey, r.EnrollmentKey, subject.SubjectKey, subject.DepartmentKey,
       learner.CampusKey * 100 + subject.DepartmentKey, assessment.DateKey,
       r.Mark, r.QualitativeOutcome
FROM dbo.AssessmentResult AS r
INNER JOIN dbo.Assessment AS assessment ON assessment.AssessmentKey = r.AssessmentKey
INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = r.TeachingAssignmentKey
INNER JOIN dbo.AnalyticsSubject AS subject ON subject.SubjectKey = ta.SubjectKey
INNER JOIN dbo.AnalyticsLearner AS learner ON learner.EnrollmentKey = r.EnrollmentKey;

COMMIT TRANSACTION;
