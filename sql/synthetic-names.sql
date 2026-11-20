SET NOCOUNT ON;

IF OBJECT_ID(N'dbo.SyntheticPersonName') IS NOT NULL
    THROW 50000, 'The synthetic name generator already exists; inspect it before continuing.', 1;
GO

CREATE FUNCTION dbo.SyntheticPersonName (
    @PersonKey int,
    @PersonType char(1)
)
RETURNS TABLE
AS
RETURN (
    SELECT CAST(firsts.Name AS nvarchar(80)) AS FirstName,
           CAST(lasts.Name AS nvarchar(80)) AS LastName
    FROM (VALUES
        (0, N'Emma'), (1, N'Daan'), (2, N'Mila'), (3, N'Sem'),
        (4, N'Sophie'), (5, N'Lucas'), (6, N'Noor'), (7, N'Finn'),
        (8, N'Eva'), (9, N'Levi'), (10, N'Sara'), (11, N'Milan'),
        (12, N'Julia'), (13, N'Bram'), (14, N'Nora'), (15, N'Mees'),
        (16, N'Tess'), (17, N'Jesse'), (18, N'Lotte'), (19, N'Olivier'),
        (20, N'Zoë'), (21, N'Daniel'), (22, N'Yara'), (23, N'Adam'),
        (24, N'Lina'), (25, N'Elias'), (26, N'Amina'), (27, N'Sam'),
        (28, N'Isa'), (29, N'Noud'), (30, N'Evi'), (31, N'Boaz'),
        (32, N'Fleur'), (33, N'Abel'), (34, N'Aylin'), (35, N'Mo'),
        (36, N'Inez'), (37, N'Niels'), (38, N'Fien'), (39, N'Raf'),
        (40, N'Chloë'), (41, N'Daniël'), (42, N'Maud'), (43, N'Mika'),
        (44, N'Senna'), (45, N'Ayla'), (46, N'Joël'), (47, N'Puck')
    ) AS firsts(NameIndex, Name)
    CROSS JOIN (VALUES
        (0, N'de Vries'), (1, N'Jansen'), (2, N'Bakker'), (3, N'Visser'),
        (4, N'van Dijk'), (5, N'van den Berg'), (6, N'Smit'), (7, N'de Jong'),
        (8, N'Mulder'), (9, N'Bos'), (10, N'Meijer'), (11, N'de Boer'),
        (12, N'de Groot'), (13, N'van der Meer'), (14, N'Vos'), (15, N'Peters'),
        (16, N'Hendriks'), (17, N'Dijkstra'), (18, N'Dekker'), (19, N'van Leeuwen'),
        (20, N'de Wit'), (21, N'van Dam'), (22, N'van Vliet'), (23, N'van der Heijden'),
        (24, N'Vermeer'), (25, N'Post'), (26, N'Kuipers'), (27, N'Verhoeven'),
        (28, N'Willems'), (29, N'de Graaf'), (30, N'Brouwer'), (31, N'van Beek'),
        (32, N'de Bruin'), (33, N'van der Linden'), (34, N'Blom'), (35, N'de Koning'),
        (36, N'van den Bosch'), (37, N'Verbeek'), (38, N'Hermans'), (39, N'Jacobs'),
        (40, N'Koster'), (41, N'van Houten'), (42, N'de Ruiter'), (43, N'Smits'),
        (44, N'Öztürk'), (45, N'El Idrissi'), (46, N'Yılmaz'), (47, N'El Amrani')
    ) AS lasts(NameIndex, Name)
    WHERE @PersonKey > 0
      AND @PersonType IN ('S', 'T')
      AND firsts.NameIndex =
          ((CONVERT(bigint, @PersonKey) - 1) + CASE WHEN @PersonType = 'T' THEN 7 ELSE 0 END) % 48
      AND lasts.NameIndex =
          (((CONVERT(bigint, @PersonKey) - 1) / 48) * 17
           + ((CONVERT(bigint, @PersonKey) - 1) % 48) * 7
           + CASE WHEN @PersonType = 'T' THEN 11 ELSE 0 END) % 48
);
GO
