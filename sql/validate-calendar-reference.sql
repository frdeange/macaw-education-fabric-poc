WITH HolidayRanges AS (
    SELECT * FROM (VALUES
        ('North', 'Summer holiday (previous school year)', CONVERT(date, '2026-07-04', 23), CONVERT(date, '2026-08-16', 23), CAST(0 AS bit)),
        ('Central', 'Summer holiday (previous school year)', CONVERT(date, '2026-07-18', 23), CONVERT(date, '2026-08-30', 23), CAST(0 AS bit)),
        ('South', 'Summer holiday (previous school year)', CONVERT(date, '2026-07-11', 23), CONVERT(date, '2026-08-23', 23), CAST(0 AS bit)),
        ('North', 'Autumn holiday', CONVERT(date, '2026-10-10', 23), CONVERT(date, '2026-10-18', 23), CAST(1 AS bit)),
        ('Central', 'Autumn holiday', CONVERT(date, '2026-10-17', 23), CONVERT(date, '2026-10-25', 23), CAST(1 AS bit)),
        ('South', 'Autumn holiday', CONVERT(date, '2026-10-17', 23), CONVERT(date, '2026-10-25', 23), CAST(1 AS bit)),
        ('North', 'Christmas holiday', CONVERT(date, '2026-12-19', 23), CONVERT(date, '2027-01-03', 23), CAST(0 AS bit)),
        ('Central', 'Christmas holiday', CONVERT(date, '2026-12-19', 23), CONVERT(date, '2027-01-03', 23), CAST(0 AS bit)),
        ('South', 'Christmas holiday', CONVERT(date, '2026-12-19', 23), CONVERT(date, '2027-01-03', 23), CAST(0 AS bit)),
        ('North', 'Spring holiday', CONVERT(date, '2027-02-20', 23), CONVERT(date, '2027-02-28', 23), CAST(1 AS bit)),
        ('Central', 'Spring holiday', CONVERT(date, '2027-02-20', 23), CONVERT(date, '2027-02-28', 23), CAST(1 AS bit)),
        ('South', 'Spring holiday', CONVERT(date, '2027-02-13', 23), CONVERT(date, '2027-02-21', 23), CAST(1 AS bit)),
        ('North', 'May holiday', CONVERT(date, '2027-04-24', 23), CONVERT(date, '2027-05-02', 23), CAST(0 AS bit)),
        ('Central', 'May holiday', CONVERT(date, '2027-04-24', 23), CONVERT(date, '2027-05-02', 23), CAST(0 AS bit)),
        ('South', 'May holiday', CONVERT(date, '2027-04-24', 23), CONVERT(date, '2027-05-02', 23), CAST(0 AS bit)),
        ('North', 'May holiday extension', CONVERT(date, '2027-05-01', 23), CONVERT(date, '2027-05-09', 23), CAST(1 AS bit)),
        ('Central', 'May holiday extension', CONVERT(date, '2027-05-01', 23), CONVERT(date, '2027-05-09', 23), CAST(1 AS bit)),
        ('South', 'May holiday extension', CONVERT(date, '2027-05-01', 23), CONVERT(date, '2027-05-09', 23), CAST(1 AS bit)),
        ('North', 'Summer holiday', CONVERT(date, '2027-07-10', 23), CONVERT(date, '2027-08-22', 23), CAST(0 AS bit)),
        ('Central', 'Summer holiday', CONVERT(date, '2027-07-17', 23), CONVERT(date, '2027-08-29', 23), CAST(0 AS bit)),
        ('South', 'Summer holiday', CONVERT(date, '2027-07-24', 23), CONVERT(date, '2027-09-05', 23), CAST(0 AS bit))
    ) AS v(Region, HolidayName, StartDate, EndDate, IsAdvisory)
),
HolidayCalendarComparison AS (
    SELECT h.HolidayName, h.IsAdvisory, c.CampusKey, d.CalendarDate,
           sc.IsInstructionDay
    FROM HolidayRanges AS h
    INNER JOIN dbo.Campus AS c ON c.HolidayRegion = h.Region
    LEFT JOIN dbo.SchoolCalendar AS sc ON sc.CampusKey = c.CampusKey
    LEFT JOIN dbo.DateDimension AS d
        ON d.DateKey = sc.DateKey
        AND d.CalendarDate BETWEEN h.StartDate AND h.EndDate
)
SELECT HolidayName, IsAdvisory,
       SUM(CASE WHEN CalendarDate IS NOT NULL AND IsInstructionDay = 1 THEN 1 ELSE 0 END)
           AS InstructionDatesMarkedOpen,
       COUNT(DISTINCT CASE WHEN CalendarDate IS NOT NULL AND IsInstructionDay = 1 THEN CampusKey END)
           AS CampusesAffected,
       MIN(CASE WHEN CalendarDate IS NOT NULL AND IsInstructionDay = 1 THEN CalendarDate END)
           AS FirstDateMarkedOpen,
       MAX(CASE WHEN CalendarDate IS NOT NULL AND IsInstructionDay = 1 THEN CalendarDate END)
           AS LastDateMarkedOpen
FROM HolidayCalendarComparison
GROUP BY HolidayName, IsAdvisory
ORDER BY HolidayName, IsAdvisory;
