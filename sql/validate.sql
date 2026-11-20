SET NOCOUNT ON;

IF (SELECT COUNT(*) FROM dbo.Campus) <> 5
    THROW 50000, 'Expected exactly five campuses.', 1;
IF (SELECT COUNT(*) FROM dbo.SchoolUnit) <> 10
    THROW 50000, 'Expected one primary and one secondary unit per campus.', 1;
IF (SELECT COUNT(*) FROM dbo.YearLevel) <> 14
    THROW 50000, 'Expected eight primary and six secondary year levels.', 1;
IF (SELECT COUNT(*) FROM dbo.ClassSection) <> 280
    THROW 50000, 'Expected exactly 280 class sections.', 1;
IF (SELECT COUNT(*) FROM dbo.Student) <> 5600 OR (SELECT COUNT(*) FROM dbo.Enrollment) <> 5600
    THROW 50000, 'Expected exactly 5,600 distinct students and enrollments.', 1;
IF EXISTS (
    SELECT c.ClassSectionKey
    FROM dbo.ClassSection AS c
    LEFT JOIN dbo.Enrollment AS e ON e.ClassSectionKey = c.ClassSectionKey
    GROUP BY c.ClassSectionKey
    HAVING COUNT(e.EnrollmentKey) <> 20
)
    THROW 50000, 'Every class section must have exactly 20 students.', 1;
IF EXISTS (
    SELECT u.CampusKey, c.YearLevelKey
    FROM dbo.ClassSection AS c
    INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
    GROUP BY u.CampusKey, c.YearLevelKey
    HAVING COUNT(*) <> 4
)
    THROW 50000, 'Every campus and year level must have four sections.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.ClassSection AS c
    INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
    INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
    WHERE u.EducationStage <> y.EducationStage
)
    THROW 50000, 'A class section belongs to the wrong educational stage.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.Enrollment AS e
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
    INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
    LEFT JOIN dbo.ProgrammeTrack AS t ON t.TrackKey = e.TrackKey
    LEFT JOIN dbo.EducationProfile AS p ON p.ProfileKey = e.ProfileKey
    WHERE (y.EducationStage = 'Primary' AND (e.TrackKey IS NOT NULL OR e.ProfileKey IS NOT NULL))
       OR (y.EducationStage = 'Secondary' AND (t.TrackKey IS NULL OR y.LevelNumber > t.DurationYears))
       OR (t.TrackName = 'VMBO' AND (
           (y.LevelNumber < 3 AND e.ProfileKey IS NOT NULL)
           OR (y.LevelNumber >= 3 AND (p.ProfileKey IS NULL OR p.ProfileGroup <> 'VMBO'))
       ))
       OR (t.TrackName IN ('HAVO', 'VWO') AND (
           (y.LevelNumber < 4 AND e.ProfileKey IS NOT NULL)
           OR (y.LevelNumber >= 4 AND (p.ProfileKey IS NULL OR p.ProfileGroup <> 'HAVO/VWO'))
       ))
)
    THROW 50000, 'An enrollment has an ineligible track or profile.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.Campus AS campus
    CROSS JOIN dbo.YearLevel AS y
    CROSS JOIN dbo.ProgrammeTrack AS t
    WHERE y.EducationStage = 'Secondary' AND y.LevelNumber <= t.DurationYears
      AND NOT EXISTS (
          SELECT 1
          FROM dbo.Enrollment AS e
          INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
          INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
          WHERE u.CampusKey = campus.CampusKey
            AND c.YearLevelKey = y.YearLevelKey AND e.TrackKey = t.TrackKey
      )
)
    THROW 50000, 'An eligible secondary track is missing from a campus year level.', 1;
IF EXISTS (
    SELECT 1 FROM dbo.Campus
    WHERE (City IN (N'Amsterdam', N'Groningen') AND HolidayRegion <> 'North')
       OR (City IN (N'Utrecht', N'Rotterdam') AND HolidayRegion <> 'Central')
       OR (City = N'Eindhoven' AND HolidayRegion <> 'South')
)
    THROW 50000, 'A campus has an incorrect school-holiday region.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.SchoolCalendar AS sc
    INNER JOIN dbo.Campus AS c ON c.CampusKey = sc.CampusKey
    INNER JOIN dbo.DateDimension AS d ON d.DateKey = sc.DateKey
    WHERE sc.IsInstructionDay = 1 AND (
        d.DayOfWeekName IN ('Saturday', 'Sunday')
        OR (c.HolidayRegion = 'North' AND d.CalendarDate BETWEEN '20261010' AND '20261018')
        OR (c.HolidayRegion IN ('Central', 'South') AND d.CalendarDate BETWEEN '20261017' AND '20261025')
        OR d.CalendarDate BETWEEN '20261219' AND '20270103'
        OR (c.HolidayRegion IN ('North', 'Central') AND d.CalendarDate BETWEEN '20270220' AND '20270228')
        OR (c.HolidayRegion = 'South' AND d.CalendarDate BETWEEN '20270213' AND '20270221')
        OR d.CalendarDate BETWEEN '20270424' AND '20270502'
    )
)
    THROW 50000, 'A weekend or configured school holiday is marked as an instruction day.', 1;
IF (SELECT COUNT(*) FROM dbo.LoadMetadata) <> 1
    THROW 50000, 'Expected one synthetic-data load metadata row.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.Attendance AS a
    INNER JOIN dbo.Enrollment AS e ON e.EnrollmentKey = a.EnrollmentKey
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
    INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
    INNER JOIN dbo.SchoolCalendar AS sc ON sc.SchoolCalendarKey = a.SchoolCalendarKey
    INNER JOIN dbo.DateDimension AS d ON d.DateKey = sc.DateKey
    CROSS JOIN dbo.LoadMetadata AS m
    WHERE sc.CampusKey <> u.CampusKey OR sc.IsInstructionDay = 0
       OR d.CalendarDate > m.SnapshotDate OR d.CalendarDate > CONVERT(date, SYSUTCDATETIME())
)
    THROW 50000, 'Attendance contains an invalid campus, non-instruction day, or future observation.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.Enrollment AS e
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
    INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
    INNER JOIN dbo.SchoolCalendar AS sc ON sc.CampusKey = u.CampusKey AND sc.IsInstructionDay = 1
    INNER JOIN dbo.DateDimension AS d ON d.DateKey = sc.DateKey
    CROSS JOIN dbo.LoadMetadata AS m
    LEFT JOIN dbo.Attendance AS a
        ON a.EnrollmentKey = e.EnrollmentKey AND a.SchoolCalendarKey = sc.SchoolCalendarKey
    WHERE d.CalendarDate <= m.SnapshotDate AND a.EnrollmentKey IS NULL
)
    THROW 50000, 'An expected observed attendance record is missing.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.EnrollmentSubject AS es
    INNER JOIN dbo.Enrollment AS e ON e.EnrollmentKey = es.EnrollmentKey
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = es.TeachingAssignmentKey
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
    INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
    WHERE ta.ClassSectionKey <> e.ClassSectionKey
       OR (y.EducationStage = 'Primary' AND y.LevelNumber <= 2 AND ta.SubjectKey NOT IN (1, 2, 3, 4))
       OR ((y.EducationStage = 'Secondary' OR y.LevelNumber > 2) AND ta.SubjectKey IN (1, 2, 3, 4))
       OR (y.EducationStage = 'Primary' AND y.LevelNumber < 5 AND ta.SubjectKey = 6)
)
    THROW 50000, 'A student has a subject from another class or an ineligible learning area.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.TeachingAssignment AS a
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = a.ClassSectionKey
    INNER JOIN dbo.Subject AS s ON s.SubjectKey = a.SubjectKey
    INNER JOIN dbo.Teacher AS t ON t.TeacherKey = a.TeacherKey
    WHERE t.SchoolUnitKey <> c.SchoolUnitKey OR t.DepartmentKey <> s.DepartmentKey
)
    THROW 50000, 'A teaching assignment has a teacher from the wrong unit or department.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.Assessment AS a
    INNER JOIN dbo.TeachingAssignment AS ta ON ta.TeachingAssignmentKey = a.TeachingAssignmentKey
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = ta.ClassSectionKey
    INNER JOIN dbo.SchoolUnit AS u ON u.SchoolUnitKey = c.SchoolUnitKey
    INNER JOIN dbo.DateDimension AS d ON d.DateKey = a.DateKey
    LEFT JOIN dbo.SchoolCalendar AS sc ON sc.CampusKey = u.CampusKey AND sc.DateKey = a.DateKey
    CROSS JOIN dbo.LoadMetadata AS m
    WHERE sc.IsInstructionDay IS NULL OR sc.IsInstructionDay = 0 OR d.CalendarDate > m.SnapshotDate
       OR d.CalendarDate > CONVERT(date, SYSUTCDATETIME())
)
    THROW 50000, 'An assessment occurs on a non-instruction day or in the future.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.AssessmentResult AS r
    INNER JOIN dbo.Enrollment AS e ON e.EnrollmentKey = r.EnrollmentKey
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
    INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
    WHERE (y.EducationStage = 'Primary' AND (r.Mark IS NOT NULL OR r.QualitativeOutcome IS NULL))
       OR (y.EducationStage = 'Secondary' AND (r.Mark IS NULL OR r.Mark < 1 OR r.Mark > 10))
)
    THROW 50000, 'An assessment result has an inappropriate outcome or mark.', 1;

SELECT 'Campuses' AS Metric, COUNT_BIG(*) AS Value FROM dbo.Campus
UNION ALL SELECT 'School units', COUNT_BIG(*) FROM dbo.SchoolUnit
UNION ALL SELECT 'Class sections', COUNT_BIG(*) FROM dbo.ClassSection
UNION ALL SELECT 'Students', COUNT_BIG(*) FROM dbo.Student
UNION ALL SELECT 'Enrollments', COUNT_BIG(*) FROM dbo.Enrollment
UNION ALL SELECT 'Teaching assignments', COUNT_BIG(*) FROM dbo.TeachingAssignment
UNION ALL SELECT 'Attendance records', COUNT_BIG(*) FROM dbo.Attendance
UNION ALL SELECT 'Assessments', COUNT_BIG(*) FROM dbo.Assessment
UNION ALL SELECT 'Assessment results', COUNT_BIG(*) FROM dbo.AssessmentResult;

SELECT m.SnapshotDate,
       CAST(100.0 * SUM(CASE WHEN a.AttendanceStatus IN ('Present', 'Late') THEN 1 ELSE 0 END)
            / NULLIF(COUNT_BIG(*), 0) AS decimal(5, 2)) AS AttendanceRatePercent
FROM dbo.Attendance AS a
CROSS JOIN dbo.LoadMetadata AS m
GROUP BY m.SnapshotDate;

SELECT t.TrackName, y.LevelNumber, COUNT(*) AS Enrollments
FROM dbo.Enrollment AS e
INNER JOIN dbo.ProgrammeTrack AS t ON t.TrackKey = e.TrackKey
INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = e.ClassSectionKey
INNER JOIN dbo.YearLevel AS y ON y.YearLevelKey = c.YearLevelKey
GROUP BY t.TrackName, y.LevelNumber
ORDER BY t.TrackName, y.LevelNumber;
