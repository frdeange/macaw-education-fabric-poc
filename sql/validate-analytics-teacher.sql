SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.AnalyticsTeacher', N'U') IS NULL
    THROW 50000, 'The teacher snapshot does not exist.', 1;
IF (SELECT COUNT_BIG(*) FROM dbo.AnalyticsTeacher) <> (SELECT COUNT_BIG(*) FROM dbo.Teacher)
   OR EXISTS (
       SELECT 1
       FROM dbo.Teacher AS teacher
       INNER JOIN dbo.SchoolUnit AS unit ON unit.SchoolUnitKey = teacher.SchoolUnitKey
       INNER JOIN dbo.Campus AS campus ON campus.CampusKey = unit.CampusKey
       INNER JOIN dbo.Department AS department ON department.DepartmentKey = teacher.DepartmentKey
       LEFT JOIN dbo.AnalyticsTeacher AS analytical ON analytical.TeacherKey = teacher.TeacherKey
       WHERE analytical.TeacherKey IS NULL
          OR CONVERT(varbinary(12), analytical.TeacherCode) <> CONVERT(varbinary(12), teacher.TeacherCode)
          OR CONVERT(varbinary(160), analytical.FirstName) <> CONVERT(varbinary(160), teacher.FirstName)
          OR CONVERT(varbinary(160), analytical.LastName) <> CONVERT(varbinary(160), teacher.LastName)
          OR analytical.CampusKey <> campus.CampusKey
          OR CONVERT(varbinary(200), analytical.CampusName) <> CONVERT(varbinary(200), campus.CampusName)
          OR CONVERT(varbinary(240), analytical.SchoolUnitName) <> CONVERT(varbinary(240), unit.SchoolUnitName)
          OR CONVERT(varbinary(10), analytical.EducationStage) <> CONVERT(varbinary(10), unit.EducationStage)
          OR analytical.DepartmentKey <> department.DepartmentKey
          OR CONVERT(varbinary(160), analytical.DepartmentName) <> CONVERT(varbinary(160), department.DepartmentName)
          OR analytical.CampusDepartmentKey <> campus.CampusKey * 100 + department.DepartmentKey
   )
    THROW 50000, 'The teacher snapshot differs from its operational source.', 1;

SELECT COUNT_BIG(*) AS Teachers,
       COUNT(DISTINCT TeacherCode) AS TeacherCodes,
       COUNT(DISTINCT CampusDepartmentKey) AS CampusDepartmentPairs
FROM dbo.AnalyticsTeacher;
