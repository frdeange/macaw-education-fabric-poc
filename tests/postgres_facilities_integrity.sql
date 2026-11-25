-- Run only against a disposable database initialized with the facilities seed.
BEGIN;

DO $$
DECLARE
    selected_room public.facility_room%ROWTYPE;
    selected_closure public.facility_closure%ROWTYPE;
BEGIN
    SELECT * INTO STRICT selected_room
    FROM public.facility_room
    ORDER BY room_key
    LIMIT 1;
    SELECT * INTO STRICT selected_closure
    FROM public.facility_closure
    ORDER BY closure_key
    LIMIT 1;

    BEGIN
        INSERT INTO public.facility_room (room_key, campus_key, room_code, room_type, capacity)
        VALUES (
            selected_room.room_key, selected_room.campus_key, 'ZZ-TEST-ROOM',
            selected_room.room_type, selected_room.capacity
        );
        RAISE EXCEPTION 'A duplicate room key was allowed.';
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;

    BEGIN
        INSERT INTO public.facility_closure (
            closure_key, campus_key, room_code, closure_date, closure_reason, status, source_version
        )
        VALUES (
            selected_closure.closure_key, selected_closure.campus_key, selected_closure.room_code,
            DATE '2099-12-31', selected_closure.closure_reason, selected_closure.status,
            selected_closure.source_version
        );
        RAISE EXCEPTION 'A duplicate closure key was allowed.';
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;

    BEGIN
        UPDATE public.facility_closure
        SET campus_key = CASE WHEN selected_closure.campus_key = 5 THEN 1
                              ELSE selected_closure.campus_key + 1 END
        WHERE closure_key = selected_closure.closure_key;
        RAISE EXCEPTION 'A closure was allowed to reference a room at another campus.';
    EXCEPTION WHEN foreign_key_violation THEN
        NULL;
    END;

    BEGIN
        DELETE FROM public.facility_room
        WHERE campus_key = selected_closure.campus_key
          AND room_code = selected_closure.room_code;
        RAISE EXCEPTION 'A room referenced by a closure was allowed to be deleted.';
    EXCEPTION WHEN foreign_key_violation THEN
        NULL;
    END;
END;
$$;

ROLLBACK;
