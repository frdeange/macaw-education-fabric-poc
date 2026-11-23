BEGIN;

INSERT INTO public.facility_seed_metadata (
    seed_key,
    school_year,
    scenario_version,
    observation_snapshot_date
)
VALUES (1, '2026-2027', '1.0', DATE '2026-11-20');

WITH campus_keys (campus_key) AS (
    VALUES (1), (2), (3), (4), (5)
),
section_numbers (section_number) AS (
    VALUES
        (1), (2), (3), (4), (5), (6), (7), (8), (9), (10),
        (11), (12), (13), (14), (15), (16), (17), (18), (19), (20),
        (21), (22), (23), (24), (25), (26), (27), (28), (29), (30),
        (31), (32), (33), (34), (35), (36), (37), (38), (39), (40),
        (41), (42), (43), (44), (45), (46), (47), (48), (49), (50),
        (51), (52), (53), (54), (55), (56)
)
INSERT INTO public.facility_room (
    room_key,
    campus_key,
    room_code,
    room_type,
    capacity,
    class_section_key,
    is_instruction_space
)
SELECT
    100000 + (campus_key - 1) * 60 + section_number,
    campus_key,
    'C' || campus_key::text || '-H' || section_number::text,
    'Classroom',
    24,
    (campus_key - 1) * 56 + section_number,
    TRUE
FROM campus_keys
CROSS JOIN section_numbers;

WITH campus_keys (campus_key) AS (
    VALUES (1), (2), (3), (4), (5)
),
specialist_rooms (room_number, room_suffix, room_type, capacity) AS (
    VALUES
        (57, 'SCI', 'ScienceLab', 28),
        (58, 'ART', 'CreativeArtsStudio', 28),
        (59, 'SPORT', 'SportsHall', 60),
        (60, 'FLEX', 'FlexibleRoom', 24)
)
INSERT INTO public.facility_room (
    room_key,
    campus_key,
    room_code,
    room_type,
    capacity,
    class_section_key,
    is_instruction_space
)
SELECT
    100000 + (campus_key - 1) * 60 + room_number,
    campus_key,
    'C' || campus_key::text || '-' || room_suffix,
    room_type,
    capacity,
    NULL::integer,
    TRUE
FROM campus_keys
CROSS JOIN specialist_rooms;

INSERT INTO public.facility_room_closure (
    closure_key,
    room_key,
    closure_date,
    start_time,
    end_time,
    time_zone,
    closure_status,
    closure_reason
)
SELECT
    campus_key,
    100000 + (campus_key - 1) * 60 + 57,
    DATE '2026-12-03',
    TIME '09:00',
    TIME '11:00',
    'Europe/Amsterdam',
    'Planned',
    'Synthetic planned maintenance'
FROM (VALUES (1), (2), (3), (4), (5)) AS campus_keys (campus_key);

COMMIT;
