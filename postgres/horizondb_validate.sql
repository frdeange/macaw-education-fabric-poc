DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM (VALUES
            ('facility_room', 'p', ARRAY['room_key']::text[], NULL::text, ARRAY[]::text[]),
            ('facility_closure', 'p', ARRAY['closure_key']::text[], NULL::text, ARRAY[]::text[]),
            (
                'facility_closure', 'f', ARRAY['campus_key', 'room_code']::text[],
                'facility_room', ARRAY['campus_key', 'room_code']::text[]
            )
        ) AS required(table_name, constraint_type, columns, referenced_table, referenced_columns)
        WHERE NOT EXISTS (
            SELECT 1
            FROM pg_catalog.pg_constraint AS constraint_info
            INNER JOIN pg_catalog.pg_class AS source
                ON source.oid = constraint_info.conrelid
            INNER JOIN pg_catalog.pg_namespace AS source_schema
                ON source_schema.oid = source.relnamespace
            LEFT JOIN pg_catalog.pg_class AS referenced
                ON referenced.oid = constraint_info.confrelid
            LEFT JOIN pg_catalog.pg_namespace AS referenced_schema
                ON referenced_schema.oid = referenced.relnamespace
            WHERE source_schema.nspname = 'public'
              AND source.relname = required.table_name
              AND source.relkind = 'r'
              AND constraint_info.contype::text = required.constraint_type
              AND constraint_info.convalidated
              AND ARRAY(
                  SELECT attribute.attname::text
                  FROM unnest(constraint_info.conkey) WITH ORDINALITY AS key_column(attnum, position)
                  INNER JOIN pg_catalog.pg_attribute AS attribute
                      ON attribute.attrelid = source.oid AND attribute.attnum = key_column.attnum
                  ORDER BY key_column.position
              ) = required.columns
              AND (
                  required.referenced_table IS NULL
                  OR (
                      referenced_schema.nspname = 'public'
                      AND referenced.relname = required.referenced_table
                  )
              )
              AND ARRAY(
                  SELECT attribute.attname::text
                  FROM unnest(constraint_info.confkey) WITH ORDINALITY AS key_column(attnum, position)
                  INNER JOIN pg_catalog.pg_attribute AS attribute
                      ON attribute.attrelid = referenced.oid AND attribute.attnum = key_column.attnum
                  ORDER BY key_column.position
              ) = required.referenced_columns
        )
    ) THEN
        RAISE EXCEPTION 'Facilities tables must have the expected primary keys and validated campus-room foreign key.';
    END IF;
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
