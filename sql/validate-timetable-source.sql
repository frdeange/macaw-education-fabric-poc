WITH PupilSubjects AS (
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
        ))
),
ClassSubjects AS (
    SELECT DISTINCT ClassSectionKey, SubjectKey
    FROM PupilSubjects
),
ExpectedAssignments AS (
    SELECT CONVERT(int, ROW_NUMBER() OVER (ORDER BY p.ClassSectionKey, p.SubjectKey))
               AS TeachingAssignmentKey,
           p.ClassSectionKey,
           p.SubjectKey,
           t.TeacherKey
    FROM ClassSubjects AS p
    INNER JOIN dbo.ClassSection AS c ON c.ClassSectionKey = p.ClassSectionKey
    INNER JOIN dbo.Subject AS s ON s.SubjectKey = p.SubjectKey
    INNER JOIN dbo.Teacher AS t ON t.SchoolUnitKey = c.SchoolUnitKey
        AND t.DepartmentKey = s.DepartmentKey
        AND t.TeacherSequence = ((s.SubjectKey - 1) % 4) + 1
),
MismatchRows AS (
    SELECT e.TeachingAssignmentKey
    FROM ExpectedAssignments AS e
    LEFT JOIN dbo.TeachingAssignment AS ta
        ON ta.TeachingAssignmentKey = e.TeachingAssignmentKey
        AND ta.ClassSectionKey = e.ClassSectionKey
        AND ta.SubjectKey = e.SubjectKey
        AND ta.TeacherKey = e.TeacherKey
    WHERE ta.TeachingAssignmentKey IS NULL
    UNION ALL
    SELECT ta.TeachingAssignmentKey
    FROM dbo.TeachingAssignment AS ta
    LEFT JOIN ExpectedAssignments AS e
        ON e.TeachingAssignmentKey = ta.TeachingAssignmentKey
        AND e.ClassSectionKey = ta.ClassSectionKey
        AND e.SubjectKey = ta.SubjectKey
        AND e.TeacherKey = ta.TeacherKey
    WHERE e.TeachingAssignmentKey IS NULL
)
SELECT
    (SELECT COUNT(*) FROM ExpectedAssignments) AS ReconstructedAssignmentCount,
    (SELECT COUNT(*) FROM dbo.TeachingAssignment) AS SourceAssignmentCount,
    (SELECT COUNT(*) FROM MismatchRows) AS AssignmentMismatchRows;
