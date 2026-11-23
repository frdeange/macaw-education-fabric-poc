SELECT
    room_type,
    COUNT(*) AS room_count,
    MIN(capacity) AS minimum_capacity,
    MAX(capacity) AS maximum_capacity
FROM public.facility_room
GROUP BY room_type
ORDER BY room_type;

SELECT
    COUNT(*) AS classroom_count,
    COUNT(DISTINCT class_section_key) AS distinct_class_sections,
    COUNT(*) FILTER (
        WHERE class_section_key <> (campus_key - 1) * 56
            + (room_key - 100000 - (campus_key - 1) * 60)
    ) AS invalid_class_section_mappings
FROM public.facility_room
WHERE room_type = 'Classroom';

SELECT
    COUNT(*) AS total_room_count,
    COUNT(DISTINCT room_key) AS distinct_room_keys,
    COUNT(DISTINCT (campus_key, room_code)) AS distinct_campus_room_codes
FROM public.facility_room;

SELECT
    closure_status,
    closure_date,
    time_zone,
    COUNT(*) AS closure_count,
    COUNT(*) FILTER (
        WHERE closure_date <= metadata.observation_snapshot_date
    ) AS closures_on_or_before_snapshot
FROM public.facility_room_closure
CROSS JOIN public.facility_seed_metadata AS metadata
GROUP BY closure_status, closure_date, time_zone, metadata.observation_snapshot_date
ORDER BY closure_date, closure_status;

SELECT
    school_year,
    scenario_version,
    observation_snapshot_date
FROM public.facility_seed_metadata
WHERE seed_key = 1;
