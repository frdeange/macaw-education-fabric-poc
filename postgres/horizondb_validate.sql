DO $$
BEGIN
    IF (SELECT COUNT(*) FROM public.facility_room) <> 300 THEN
        RAISE EXCEPTION 'Expected 300 synthetic rooms.';
    END IF;
    IF (SELECT COUNT(DISTINCT campus_key) FROM public.facility_room) <> 5 THEN
        RAISE EXCEPTION 'Expected rooms for all five campuses.';
    END IF;
    IF EXISTS (
        SELECT campus_key
        FROM public.facility_room
        GROUP BY campus_key
        HAVING COUNT(*) <> 60
    ) THEN
        RAISE EXCEPTION 'Each campus must have 60 synthetic rooms.';
    END IF;
    IF (SELECT COUNT(*) FROM public.facility_room WHERE room_type = 'Classroom' AND capacity = 24) <> 280
       OR (SELECT COUNT(*) FROM public.facility_room WHERE room_type = 'ScienceLab' AND capacity = 28) <> 10
       OR (SELECT COUNT(*) FROM public.facility_room WHERE room_type = 'ArtStudio' AND capacity = 24) <> 10 THEN
        RAISE EXCEPTION 'Room types or capacities differ from the synthetic source contract.';
    END IF;
    IF (SELECT COUNT(*) FROM public.facility_closure) <> 10 THEN
        RAISE EXCEPTION 'Expected ten planned room closures.';
    END IF;
    IF EXISTS (
        SELECT campus_key
        FROM public.facility_closure
        GROUP BY campus_key
        HAVING COUNT(*) <> 2
    ) THEN
        RAISE EXCEPTION 'Each campus must have two planned room closures.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.facility_closure AS closure
        LEFT JOIN public.facility_room AS room
            ON room.campus_key = closure.campus_key
            AND room.room_code = closure.room_code
        WHERE room.room_key IS NULL
           OR closure.status <> 'Planned'
           OR EXTRACT(ISODOW FROM closure.closure_date) <> 2
           OR closure.closure_date <= DATE '2026-11-20'
           OR closure.source_version <> 'timetable-2026-2027-v2'
    ) THEN
        RAISE EXCEPTION 'A planned closure has an unknown room, status, date, or source version.';
    END IF;
END;
$$;

SELECT campus_key, COUNT(*) AS room_count
FROM public.facility_room
GROUP BY campus_key
ORDER BY campus_key;

SELECT campus_key, COUNT(*) AS planned_closure_count
FROM public.facility_closure
GROUP BY campus_key
ORDER BY campus_key;
