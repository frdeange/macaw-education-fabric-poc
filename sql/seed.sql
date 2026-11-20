SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @SnapshotDate date = TRY_CONVERT(date, N'$(SnapshotDate)', 23);
IF @SnapshotDate IS NULL OR @SnapshotDate < '20260817'
    THROW 50000, 'SnapshotDate must be an ISO date on or after 2026-08-17.', 1;
IF @SnapshotDate > CONVERT(date, SYSUTCDATETIME())
    THROW 50000, 'SnapshotDate cannot be in the future.', 1;
IF EXISTS (SELECT 1 FROM dbo.Campus) OR EXISTS (SELECT 1 FROM dbo.LoadMetadata)
    THROW 50000, 'The target database is not empty; inspect it before loading synthetic data.', 1;
IF OBJECT_ID(N'dbo.SyntheticPersonName', N'IF') IS NULL
    THROW 50000, 'Create the synthetic name generator before seeding the database.', 1;

BEGIN TRANSACTION;

INSERT dbo.Campus (CampusKey, CampusName, City, HolidayRegion)
VALUES
    (1, N'Macaw Amsterdam Campus', N'Amsterdam', 'North'),
    (2, N'Macaw Utrecht Campus', N'Utrecht', 'Central'),
    (3, N'Macaw Rotterdam Campus', N'Rotterdam', 'Central'),
    (4, N'Macaw Eindhoven Campus', N'Eindhoven', 'South'),
    (5, N'Macaw Groningen Campus', N'Groningen', 'North');

INSERT dbo.SchoolUnit (SchoolUnitKey, CampusKey, SchoolUnitName, EducationStage)
SELECT (c.CampusKey - 1) * 2 + s.UnitNumber, c.CampusKey,
       c.CampusName + N' - ' + s.EducationStage, s.EducationStage
FROM dbo.Campus AS c
CROSS JOIN (VALUES (1, 'Primary'), (2, 'Secondary')) AS s(UnitNumber, EducationStage);

INSERT dbo.AcademicYear (AcademicYearKey, AcademicYearName, FirstDate, LastDate)
VALUES (2026, '2026-2027', '20260817', '20270723');

INSERT dbo.YearLevel (YearLevelKey, EducationStage, LevelNumber, YearLevelName)
SELECT n.LevelNumber, 'Primary', n.LevelNumber,
       N'Primary Group ' + CONVERT(nvarchar(2), n.LevelNumber)
FROM (VALUES (1), (2), (3), (4), (5), (6), (7), (8)) AS n(LevelNumber)
UNION ALL
SELECT n.LevelNumber + 8, 'Secondary', n.LevelNumber,
       N'Secondary Year ' + CONVERT(nvarchar(2), n.LevelNumber)
FROM (VALUES (1), (2), (3), (4), (5), (6)) AS n(LevelNumber);

INSERT dbo.ProgrammeTrack (TrackKey, TrackName, DurationYears)
VALUES (1, 'VMBO', 4), (2, 'HAVO', 5), (3, 'VWO', 6);

INSERT dbo.EducationProfile (ProfileKey, ProfileName, ProfileGroup)
VALUES
    (1, N'Science and Technology', 'HAVO/VWO'),
    (2, N'Science and Health', 'HAVO/VWO'),
    (3, N'Economics and Society', 'HAVO/VWO'),
    (4, N'Culture and Society', 'HAVO/VWO'),
    (5, N'Production, Installation and Energy', 'VMBO'),
    (6, N'Care and Wellbeing', 'VMBO'),
    (7, N'Economics and Enterprise', 'VMBO'),
    (8, N'Green', 'VMBO');

INSERT dbo.Department (DepartmentKey, DepartmentName)
VALUES
    (1, N'Languages'),
    (2, N'Mathematics'),
    (3, N'Science and Technology'),
    (4, N'Social and Environmental Studies'),
    (5, N'Creative Arts'),
    (6, N'Physical Education');

INSERT dbo.Subject (SubjectKey, SubjectName, DepartmentKey)
VALUES
    (1, N'Early Language and Literacy', 1),
    (2, N'Early Numeracy and Patterns', 2),
    (3, N'Learning Through Play', 5),
    (4, N'Movement', 6),
    (5, N'Dutch', 1),
    (6, N'English', 1),
    (7, N'Mathematics', 2),
    (8, N'Social and Environmental Studies', 4),
    (9, N'Science and Technology', 3),
    (10, N'Creative Arts', 5),
    (11, N'Physical Education', 6),
    (12, N'Biology', 3),
    (13, N'Physics', 3),
    (14, N'Chemistry', 3),
    (15, N'History', 4),
    (16, N'Geography', 4),
    (17, N'Economics', 4),
    (18, N'German', 1),
    (19, N'French', 1),
    (20, N'Social Studies', 4),
    (21, N'Culture and Arts', 5);

INSERT dbo.Teacher (TeacherKey, TeacherCode, FirstName, LastName, SchoolUnitKey, DepartmentKey, TeacherSequence)
SELECT t.TeacherKey, 'T' + RIGHT('0000' + CONVERT(varchar(4), t.TeacherKey), 4),
       person.FirstName, person.LastName, u.SchoolUnitKey, d.DepartmentKey, s.TeacherSequence
FROM dbo.SchoolUnit AS u
CROSS JOIN dbo.Department AS d
CROSS JOIN (VALUES (1), (2), (3), (4)) AS s(TeacherSequence)
CROSS APPLY (VALUES ((u.SchoolUnitKey - 1) * 24 + (d.DepartmentKey - 1) * 4 + s.TeacherSequence))
    AS t(TeacherKey)
CROSS APPLY dbo.SyntheticPersonName(t.TeacherKey, 'T') AS person;

INSERT dbo.ClassSection (ClassSectionKey, SchoolUnitKey, AcademicYearKey, YearLevelKey, SectionCode)
SELECT (c.CampusKey - 1) * 56 + (y.YearLevelKey - 1) * 4 + s.SectionNumber,
       u.SchoolUnitKey, 2026, y.YearLevelKey, s.SectionCode
FROM dbo.Campus AS c
CROSS JOIN dbo.YearLevel AS y
INNER JOIN dbo.SchoolUnit AS u
    ON u.CampusKey = c.CampusKey AND u.EducationStage = y.EducationStage
CROSS JOIN (VALUES (1, 'A'), (2, 'B'), (3, 'C'), (4, 'D')) AS s(SectionNumber, SectionCode);

INSERT dbo.Student (StudentKey, StudentCode, FirstName, LastName)
SELECT k.StudentKey, 'S' + RIGHT('00000' + CONVERT(varchar(5), k.StudentKey), 5),
       person.FirstName, person.LastName
FROM dbo.ClassSection AS c
CROSS JOIN (VALUES
    (1), (2), (3), (4), (5), (6), (7), (8), (9), (10),
    (11), (12), (13), (14), (15), (16), (17), (18), (19), (20)
) AS n(StudentNumber)
CROSS APPLY (VALUES ((c.ClassSectionKey - 1) * 20 + n.StudentNumber)) AS k(StudentKey)
CROSS APPLY dbo.SyntheticPersonName(k.StudentKey, 'S') AS person;

INSERT dbo.Enrollment (EnrollmentKey, StudentKey, ClassSectionKey, TrackKey, ProfileKey)
SELECT s.StudentKey, s.StudentKey, c.ClassSectionKey, t.TrackKey,
       CASE
           WHEN t.TrackKey IN (2, 3) AND y.LevelNumber >= 4 THEN ((s.StudentKey - 1) % 4) + 1
           WHEN t.TrackKey = 1 AND y.LevelNumber >= 3 THEN ((s.StudentKey - 1) % 4) + 5
           ELSE NULL
       END
FROM dbo.Student AS s
INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = ((s.StudentKey - 1) / 20) + 1
INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
CROSS APPLY (VALUES (
    CASE
        WHEN y.EducationStage = 'Primary' THEN NULL
        WHEN y.LevelNumber <= 4 AND c.SectionCode IN ('A', 'D') THEN 1
        WHEN y.LevelNumber <= 4 AND c.SectionCode = 'B' THEN 2
        WHEN y.LevelNumber <= 4 AND c.SectionCode = 'C' THEN 3
        WHEN y.LevelNumber = 5 AND c.SectionCode IN ('A', 'B') THEN 2
        ELSE 3
    END
)) AS t(TrackKey);

WITH Digits AS (
    SELECT n FROM (VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9)) AS d(n)
), Numbers AS (
    SELECT a.n * 100 + b.n * 10 + c.n AS n
    FROM Digits AS a CROSS JOIN Digits AS b CROSS JOIN Digits AS c
), Dates AS (
    SELECT DATEADD(day, n, CONVERT(date, '20260817', 112)) AS CalendarDate
    FROM Numbers
    WHERE n <= DATEDIFF(day, CONVERT(date, '20260817', 112), CONVERT(date, '20270723', 112))
)
INSERT dbo.DateDimension (DateKey, CalendarDate, CalendarYear, MonthNumber, MonthName, DayOfWeekName)
SELECT CONVERT(int, CONVERT(char(8), d.CalendarDate, 112)), d.CalendarDate,
       YEAR(d.CalendarDate), MONTH(d.CalendarDate),
       CHOOSE(MONTH(d.CalendarDate), 'January', 'February', 'March', 'April', 'May', 'June',
              'July', 'August', 'September', 'October', 'November', 'December'),
       CHOOSE((DATEDIFF(day, CONVERT(date, '19000101', 112), d.CalendarDate) % 7) + 1,
              'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
FROM Dates AS d;

INSERT dbo.SchoolCalendar (SchoolCalendarKey, CampusKey, DateKey, IsInstructionDay, ClosureReason)
SELECT c.CampusKey * 1000 + DATEDIFF(day, CONVERT(date, '20260817', 112), d.CalendarDate),
       c.CampusKey, d.DateKey, CASE WHEN r.ClosureReason IS NULL THEN 1 ELSE 0 END, r.ClosureReason
FROM dbo.Campus AS c
CROSS JOIN dbo.DateDimension AS d
CROSS APPLY (VALUES (
    CASE
        WHEN (c.HolidayRegion = 'Central' AND d.CalendarDate < '20260831')
          OR (c.HolidayRegion = 'South' AND d.CalendarDate < '20260824')
          OR (c.HolidayRegion = 'North' AND d.CalendarDate >= '20270710')
          OR (c.HolidayRegion = 'Central' AND d.CalendarDate >= '20270717')
          OR (c.HolidayRegion = 'South' AND d.CalendarDate >= '20270724')
            THEN N'Outside academic year'
        WHEN DATEDIFF(day, CONVERT(date, '19000101', 112), d.CalendarDate) % 7 IN (5, 6)
            THEN N'Weekend'
        WHEN (c.HolidayRegion = 'North' AND d.CalendarDate BETWEEN '20261010' AND '20261018')
          OR (c.HolidayRegion IN ('Central', 'South') AND d.CalendarDate BETWEEN '20261017' AND '20261025')
            THEN N'Autumn holiday'
        WHEN d.CalendarDate BETWEEN '20261219' AND '20270103'
            THEN N'Christmas holiday'
        WHEN (c.HolidayRegion IN ('North', 'Central') AND d.CalendarDate BETWEEN '20270220' AND '20270228')
          OR (c.HolidayRegion = 'South' AND d.CalendarDate BETWEEN '20270213' AND '20270221')
            THEN N'Spring holiday'
        WHEN d.CalendarDate BETWEEN '20270424' AND '20270502'
            THEN N'May holiday'
        WHEN d.CalendarDate IN ('20270326', '20270329', '20270506', '20270517')
            THEN N'Fictional school closure'
        ELSE NULL
    END
)) AS r(ClosureReason);

CREATE TABLE #PupilSubjects (
    EnrollmentKey int NOT NULL,
    ClassSectionKey int NOT NULL,
    SubjectKey int NOT NULL,
    PRIMARY KEY (EnrollmentKey, SubjectKey)
);

INSERT #PupilSubjects (EnrollmentKey, ClassSectionKey, SubjectKey)
SELECT e.EnrollmentKey, c.ClassSectionKey, s.SubjectKey
FROM dbo.Enrollment AS e
INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
CROSS JOIN dbo.Subject AS s
WHERE
    (y.EducationStage = 'Primary' AND (
        (y.LevelNumber <= 2 AND s.SubjectKey IN (1, 2, 3, 4))
        OR (y.LevelNumber >= 3 AND s.SubjectKey IN (5, 7, 8, 9, 10, 11))
        OR (y.LevelNumber >= 5 AND s.SubjectKey = 6)
    ))
    OR
    (y.EducationStage = 'Secondary' AND (
        s.SubjectKey IN (5, 6, 7, 11, 20, 21)
        OR (y.LevelNumber <= 3 AND s.SubjectKey IN (9, 10, 12, 15, 16))
        OR (y.LevelNumber BETWEEN 2 AND 3 AND e.TrackKey IN (2, 3) AND s.SubjectKey = 18)
        OR (e.TrackKey = 1 AND y.LevelNumber >= 3 AND (
            (e.ProfileKey = 5 AND s.SubjectKey IN (9, 13, 14))
            OR (e.ProfileKey = 6 AND s.SubjectKey = 12)
            OR (e.ProfileKey = 7 AND s.SubjectKey IN (17, 18))
            OR (e.ProfileKey = 8 AND s.SubjectKey IN (9, 12))
        ))
        OR (e.TrackKey IN (2, 3) AND y.LevelNumber >= 4 AND (
            (e.ProfileKey = 1 AND s.SubjectKey IN (9, 13, 14))
            OR (e.ProfileKey = 2 AND s.SubjectKey IN (12, 14))
            OR (e.ProfileKey = 3 AND s.SubjectKey IN (15, 17))
            OR (e.ProfileKey = 4 AND s.SubjectKey IN (15, 19))
        ))
        OR (e.TrackKey = 3 AND y.LevelNumber >= 4 AND s.SubjectKey = 18)
    ));

WITH ClassSubjects AS (
    SELECT DISTINCT ClassSectionKey, SubjectKey
    FROM #PupilSubjects
)
INSERT dbo.TeachingAssignment (TeachingAssignmentKey, ClassSectionKey, SubjectKey, TeacherKey)
SELECT CONVERT(int, ROW_NUMBER() OVER (ORDER BY p.ClassSectionKey, p.SubjectKey)),
       p.ClassSectionKey, p.SubjectKey, t.TeacherKey
FROM ClassSubjects AS p
INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = p.ClassSectionKey
INNER JOIN dbo.Subject AS s ON s.SubjectKey = p.SubjectKey
INNER JOIN dbo.Teacher AS t ON t.SchoolUnitKey = c.SchoolUnitKey
    AND t.DepartmentKey = s.DepartmentKey
    AND t.TeacherSequence = ((s.SubjectKey - 1) % 4) + 1;

INSERT dbo.EnrollmentSubject (EnrollmentKey, TeachingAssignmentKey)
SELECT p.EnrollmentKey, a.TeachingAssignmentKey
FROM #PupilSubjects AS p
INNER JOIN dbo.TeachingAssignment AS a
    ON a.ClassSectionKey = p.ClassSectionKey AND a.SubjectKey = p.SubjectKey;

DROP TABLE #PupilSubjects;

WITH InstructionDays AS (
    SELECT CampusKey, DateKey,
           ROW_NUMBER() OVER (PARTITION BY CampusKey ORDER BY DateKey) AS InstructionDayNumber
    FROM dbo.SchoolCalendar
    WHERE IsInstructionDay = 1
)
INSERT dbo.Assessment (AssessmentKey, TeachingAssignmentKey, DateKey, AssessmentPeriod, AssessmentType)
SELECT a.TeachingAssignmentKey * 10 + p.AssessmentPeriod, a.TeachingAssignmentKey,
       d.DateKey, p.AssessmentPeriod,
       CASE WHEN y.EducationStage = 'Primary' THEN 'Formative observation' ELSE 'School assessment' END
FROM dbo.TeachingAssignment AS a
INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = a.ClassSectionKey
INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
CROSS JOIN (VALUES (1, 20), (2, 45)) AS p(AssessmentPeriod, InstructionDayNumber)
INNER JOIN InstructionDays AS d
    ON d.CampusKey = u.CampusKey AND d.InstructionDayNumber = p.InstructionDayNumber
INNER JOIN dbo.DateDimension AS dd ON dd.DateKey = d.DateKey AND dd.CalendarDate <= @SnapshotDate;

INSERT dbo.AssessmentResult (AssessmentKey, EnrollmentKey, TeachingAssignmentKey, Mark, QualitativeOutcome)
SELECT a.AssessmentKey, es.EnrollmentKey, a.TeachingAssignmentKey,
       CASE WHEN y.EducationStage = 'Secondary'
            THEN CONVERT(decimal(3, 1),
                 4.0 + ((es.EnrollmentKey * 37 + ta.SubjectKey * 17 + a.AssessmentPeriod * 13) % 56) / 10.0)
            ELSE NULL END,
       CASE WHEN y.EducationStage = 'Primary'
            THEN CHOOSE(((es.EnrollmentKey + ta.SubjectKey + a.AssessmentPeriod) % 3) + 1,
                        'Emerging', 'Developing', 'Secure')
            ELSE NULL END
FROM dbo.Assessment AS a
INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = a.TeachingAssignmentKey
INNER JOIN dbo.EnrollmentSubject AS es ON es.TeachingAssignmentKey = ta.TeachingAssignmentKey
INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = ta.ClassSectionKey
INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey;

INSERT dbo.Attendance (EnrollmentKey, SchoolCalendarKey, AttendanceStatus)
SELECT e.EnrollmentKey, sc.SchoolCalendarKey,
       CASE
           WHEN v.StatusNumber < 89 THEN 'Present'
           WHEN v.StatusNumber < 94 THEN 'Late'
           WHEN v.StatusNumber < 98 THEN 'Authorized absence'
           ELSE 'Unauthorized absence'
       END
FROM dbo.Enrollment AS e
INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
INNER JOIN dbo.SchoolCalendar AS sc ON sc.CampusKey = u.CampusKey AND sc.IsInstructionDay = 1
INNER JOIN dbo.DateDimension AS d ON d.DateKey = sc.DateKey AND d.CalendarDate <= @SnapshotDate
CROSS APPLY (VALUES ((e.EnrollmentKey * 37 + sc.SchoolCalendarKey * 17) % 100)) AS v(StatusNumber);

INSERT dbo.LoadMetadata (LoadKey, AcademicYearKey, SnapshotDate, ScenarioVersion)
VALUES (1, 2026, @SnapshotDate, '1.0');

COMMIT TRANSACTION;
