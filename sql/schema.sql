SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (
    SELECT 1
    FROM sys.tables
    WHERE schema_id = SCHEMA_ID(N'dbo')
      AND name IN (
          N'Campus', N'SchoolUnit', N'AcademicYear', N'YearLevel',
          N'ProgrammeTrack', N'EducationProfile', N'Department', N'Subject',
          N'Teacher', N'ClassSection', N'Student', N'Enrollment',
          N'DateDimension', N'SchoolCalendar', N'TeachingAssignment',
          N'EnrollmentSubject', N'Assessment', N'AssessmentResult',
          N'Attendance', N'LoadMetadata'
      )
)
    THROW 50000, 'A target table already exists; inspect the database before applying the schema.', 1;

BEGIN TRANSACTION;

CREATE TABLE dbo.Campus (
    CampusKey int NOT NULL PRIMARY KEY,
    CampusName nvarchar(100) NOT NULL UNIQUE,
    City nvarchar(50) NOT NULL,
    HolidayRegion varchar(10) NOT NULL CHECK (HolidayRegion IN ('North', 'Central', 'South'))
);

CREATE TABLE dbo.SchoolUnit (
    SchoolUnitKey int NOT NULL PRIMARY KEY,
    CampusKey int NOT NULL REFERENCES dbo.Campus(CampusKey),
    SchoolUnitName nvarchar(120) NOT NULL,
    EducationStage varchar(10) NOT NULL CHECK (EducationStage IN ('Primary', 'Secondary')),
    CONSTRAINT UQ_SchoolUnit_CampusStage UNIQUE (CampusKey, EducationStage)
);

CREATE TABLE dbo.AcademicYear (
    AcademicYearKey int NOT NULL PRIMARY KEY,
    AcademicYearName varchar(9) NOT NULL UNIQUE,
    FirstDate date NOT NULL,
    LastDate date NOT NULL,
    CHECK (FirstDate <= LastDate)
);

CREATE TABLE dbo.YearLevel (
    YearLevelKey int NOT NULL PRIMARY KEY,
    EducationStage varchar(10) NOT NULL CHECK (EducationStage IN ('Primary', 'Secondary')),
    LevelNumber int NOT NULL,
    YearLevelName nvarchar(40) NOT NULL UNIQUE,
    CHECK (
        (EducationStage = 'Primary' AND LevelNumber BETWEEN 1 AND 8) OR
        (EducationStage = 'Secondary' AND LevelNumber BETWEEN 1 AND 6)
    ),
    CONSTRAINT UQ_YearLevel_StageNumber UNIQUE (EducationStage, LevelNumber)
);

CREATE TABLE dbo.ProgrammeTrack (
    TrackKey int NOT NULL PRIMARY KEY,
    TrackName varchar(10) NOT NULL UNIQUE,
    DurationYears int NOT NULL CHECK (DurationYears BETWEEN 1 AND 6)
);

CREATE TABLE dbo.EducationProfile (
    ProfileKey int NOT NULL PRIMARY KEY,
    ProfileName nvarchar(80) NOT NULL UNIQUE,
    ProfileGroup varchar(20) NOT NULL CHECK (ProfileGroup IN ('HAVO/VWO', 'VMBO'))
);

CREATE TABLE dbo.Department (
    DepartmentKey int NOT NULL PRIMARY KEY,
    DepartmentName nvarchar(80) NOT NULL UNIQUE
);

CREATE TABLE dbo.Subject (
    SubjectKey int NOT NULL PRIMARY KEY,
    SubjectName nvarchar(80) NOT NULL UNIQUE,
    DepartmentKey int NOT NULL REFERENCES dbo.Department(DepartmentKey)
);

CREATE TABLE dbo.Teacher (
    TeacherKey int NOT NULL PRIMARY KEY,
    TeacherCode varchar(12) NOT NULL UNIQUE,
    FirstName nvarchar(80) NOT NULL,
    LastName nvarchar(80) NOT NULL,
    SchoolUnitKey int NOT NULL REFERENCES dbo.SchoolUnit(SchoolUnitKey),
    DepartmentKey int NOT NULL REFERENCES dbo.Department(DepartmentKey),
    TeacherSequence int NOT NULL CHECK (TeacherSequence BETWEEN 1 AND 4),
    CONSTRAINT UQ_Teacher_UnitDepartmentSequence UNIQUE (SchoolUnitKey, DepartmentKey, TeacherSequence)
);

CREATE TABLE dbo.ClassSection (
    ClassSectionKey int NOT NULL PRIMARY KEY,
    SchoolUnitKey int NOT NULL REFERENCES dbo.SchoolUnit(SchoolUnitKey),
    AcademicYearKey int NOT NULL REFERENCES dbo.AcademicYear(AcademicYearKey),
    YearLevelKey int NOT NULL REFERENCES dbo.YearLevel(YearLevelKey),
    SectionCode char(1) NOT NULL CHECK (SectionCode IN ('A', 'B', 'C', 'D')),
    CONSTRAINT UQ_ClassSection UNIQUE (SchoolUnitKey, AcademicYearKey, YearLevelKey, SectionCode)
);

CREATE TABLE dbo.Student (
    StudentKey int NOT NULL PRIMARY KEY,
    StudentCode varchar(12) NOT NULL UNIQUE,
    FirstName nvarchar(80) NOT NULL,
    LastName nvarchar(80) NOT NULL
);

CREATE TABLE dbo.Enrollment (
    EnrollmentKey int NOT NULL PRIMARY KEY,
    StudentKey int NOT NULL UNIQUE REFERENCES dbo.Student(StudentKey),
    ClassSectionKey int NOT NULL REFERENCES dbo.ClassSection(ClassSectionKey),
    TrackKey int NULL REFERENCES dbo.ProgrammeTrack(TrackKey),
    ProfileKey int NULL REFERENCES dbo.EducationProfile(ProfileKey)
);

CREATE TABLE dbo.DateDimension (
    DateKey int NOT NULL PRIMARY KEY,
    CalendarDate date NOT NULL UNIQUE,
    CalendarYear int NOT NULL,
    MonthNumber int NOT NULL,
    MonthName varchar(12) NOT NULL,
    DayOfWeekName varchar(9) NOT NULL
);

CREATE TABLE dbo.SchoolCalendar (
    SchoolCalendarKey int NOT NULL PRIMARY KEY,
    CampusKey int NOT NULL REFERENCES dbo.Campus(CampusKey),
    DateKey int NOT NULL REFERENCES dbo.DateDimension(DateKey),
    IsInstructionDay bit NOT NULL,
    ClosureReason nvarchar(40) NULL,
    CONSTRAINT UQ_SchoolCalendar_CampusDate UNIQUE (CampusKey, DateKey),
    CHECK (
        (IsInstructionDay = 1 AND ClosureReason IS NULL) OR
        (IsInstructionDay = 0 AND ClosureReason IS NOT NULL)
    )
);

CREATE TABLE dbo.TeachingAssignment (
    TeachingAssignmentKey int NOT NULL PRIMARY KEY,
    ClassSectionKey int NOT NULL REFERENCES dbo.ClassSection(ClassSectionKey),
    SubjectKey int NOT NULL REFERENCES dbo.Subject(SubjectKey),
    TeacherKey int NOT NULL REFERENCES dbo.Teacher(TeacherKey),
    CONSTRAINT UQ_TeachingAssignment_ClassSubject UNIQUE (ClassSectionKey, SubjectKey)
);

CREATE TABLE dbo.EnrollmentSubject (
    EnrollmentKey int NOT NULL REFERENCES dbo.Enrollment(EnrollmentKey),
    TeachingAssignmentKey int NOT NULL REFERENCES dbo.TeachingAssignment(TeachingAssignmentKey),
    CONSTRAINT PK_EnrollmentSubject PRIMARY KEY (EnrollmentKey, TeachingAssignmentKey)
);

CREATE TABLE dbo.Assessment (
    AssessmentKey int NOT NULL PRIMARY KEY,
    TeachingAssignmentKey int NOT NULL REFERENCES dbo.TeachingAssignment(TeachingAssignmentKey),
    DateKey int NOT NULL REFERENCES dbo.DateDimension(DateKey),
    AssessmentPeriod int NOT NULL CHECK (AssessmentPeriod IN (1, 2)),
    AssessmentType varchar(25) NOT NULL,
    CONSTRAINT UQ_Assessment_AssignmentPeriod UNIQUE (TeachingAssignmentKey, AssessmentPeriod),
    CONSTRAINT UQ_Assessment_AssignmentKey UNIQUE (AssessmentKey, TeachingAssignmentKey)
);

CREATE TABLE dbo.AssessmentResult (
    AssessmentKey int NOT NULL,
    EnrollmentKey int NOT NULL,
    TeachingAssignmentKey int NOT NULL,
    Mark decimal(3, 1) NULL CHECK (Mark BETWEEN 1.0 AND 10.0),
    QualitativeOutcome varchar(20) NULL CHECK (QualitativeOutcome IN ('Emerging', 'Developing', 'Secure')),
    CONSTRAINT PK_AssessmentResult PRIMARY KEY (AssessmentKey, EnrollmentKey),
    CONSTRAINT FK_AssessmentResult_Assessment FOREIGN KEY (AssessmentKey, TeachingAssignmentKey)
        REFERENCES dbo.Assessment(AssessmentKey, TeachingAssignmentKey),
    CONSTRAINT FK_AssessmentResult_EnrollmentSubject FOREIGN KEY (EnrollmentKey, TeachingAssignmentKey)
        REFERENCES dbo.EnrollmentSubject(EnrollmentKey, TeachingAssignmentKey),
    CHECK (
        (Mark IS NOT NULL AND QualitativeOutcome IS NULL) OR
        (Mark IS NULL AND QualitativeOutcome IS NOT NULL)
    )
);

CREATE TABLE dbo.Attendance (
    EnrollmentKey int NOT NULL REFERENCES dbo.Enrollment(EnrollmentKey),
    SchoolCalendarKey int NOT NULL REFERENCES dbo.SchoolCalendar(SchoolCalendarKey),
    AttendanceStatus varchar(20) NOT NULL
        CHECK (AttendanceStatus IN ('Present', 'Late', 'Authorized absence', 'Unauthorized absence')),
    CONSTRAINT PK_Attendance PRIMARY KEY (EnrollmentKey, SchoolCalendarKey)
);

CREATE TABLE dbo.LoadMetadata (
    LoadKey int NOT NULL PRIMARY KEY CHECK (LoadKey = 1),
    AcademicYearKey int NOT NULL REFERENCES dbo.AcademicYear(AcademicYearKey),
    SnapshotDate date NOT NULL,
    ScenarioVersion varchar(20) NOT NULL
);

COMMIT TRANSACTION;
