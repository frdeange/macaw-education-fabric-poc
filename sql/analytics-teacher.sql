SET NOCOUNT ON;
SET XACT_ABORT ON;

IF N'$(AllowTeacherSnapshot)' <> N'true'
    THROW 50000, 'Creating the teacher directory requires AllowTeacherSnapshot=true after access validation.', 1;
IF OBJECT_ID(N'dbo.AnalyticsTeacher', N'U') IS NOT NULL
    THROW 50000, 'The teacher snapshot already exists; inspect it before continuing.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Teacher)
    THROW 50000, 'Load the synthetic teachers before creating their analytical snapshot.', 1;
IF EXISTS (
    SELECT 1
    FROM dbo.Teacher AS teacher
    LEFT JOIN dbo.SchoolUnit AS unit ON unit.SchoolUnitKey = teacher.SchoolUnitKey
    LEFT JOIN dbo.Campus AS campus ON campus.CampusKey = unit.CampusKey
    LEFT JOIN dbo.Department AS department ON department.DepartmentKey = teacher.DepartmentKey
    WHERE unit.SchoolUnitKey IS NULL
       OR campus.CampusKey IS NULL
       OR department.DepartmentKey IS NULL
       OR campus.CampusKey NOT BETWEEN 1 AND 21474835
       OR department.DepartmentKey NOT BETWEEN 1 AND 99
       OR teacher.FirstName IS NULL OR LEN(LTRIM(RTRIM(teacher.FirstName))) = 0
       OR teacher.LastName IS NULL OR LEN(LTRIM(RTRIM(teacher.LastName))) = 0
)
    THROW 50000, 'A teacher has invalid names, school-unit data, or campus-department keys.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    CREATE TABLE dbo.AnalyticsTeacher (
        TeacherKey int NOT NULL PRIMARY KEY REFERENCES dbo.Teacher(TeacherKey),
        TeacherCode varchar(12) NOT NULL UNIQUE,
        FirstName nvarchar(80) NOT NULL,
        LastName nvarchar(80) NOT NULL,
        CampusKey int NOT NULL,
        CampusName nvarchar(100) NOT NULL,
        SchoolUnitName nvarchar(120) NOT NULL,
        EducationStage varchar(10) NOT NULL,
        DepartmentKey int NOT NULL,
        DepartmentName nvarchar(80) NOT NULL,
        CampusDepartmentKey int NOT NULL
    );

    INSERT dbo.AnalyticsTeacher (
        TeacherKey, TeacherCode, FirstName, LastName, CampusKey, CampusName,
        SchoolUnitName, EducationStage, DepartmentKey, DepartmentName, CampusDepartmentKey
    )
    SELECT teacher.TeacherKey, teacher.TeacherCode, teacher.FirstName, teacher.LastName,
           campus.CampusKey, campus.CampusName, unit.SchoolUnitName, unit.EducationStage,
           department.DepartmentKey, department.DepartmentName,
           campus.CampusKey * 100 + department.DepartmentKey
    FROM dbo.Teacher AS teacher
    INNER JOIN dbo.SchoolUnit AS unit ON unit.SchoolUnitKey = teacher.SchoolUnitKey
    INNER JOIN dbo.Campus AS campus ON campus.CampusKey = unit.CampusKey
    INNER JOIN dbo.Department AS department ON department.DepartmentKey = teacher.DepartmentKey;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
