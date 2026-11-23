BEGIN;

CREATE TABLE public.facility_seed_metadata (
    seed_key smallint PRIMARY KEY CHECK (seed_key = 1),
    school_year varchar(9) NOT NULL,
    scenario_version varchar(10) NOT NULL,
    observation_snapshot_date date NOT NULL
);

CREATE TABLE public.facility_room (
    room_key integer PRIMARY KEY,
    campus_key integer NOT NULL CHECK (campus_key BETWEEN 1 AND 5),
    room_code varchar(24) NOT NULL,
    room_type varchar(32) NOT NULL CHECK (
        room_type IN (
            'Classroom',
            'ScienceLab',
            'CreativeArtsStudio',
            'SportsHall',
            'FlexibleRoom'
        )
    ),
    capacity smallint NOT NULL CHECK (capacity BETWEEN 1 AND 100),
    class_section_key integer,
    is_instruction_space boolean NOT NULL,
    CONSTRAINT uq_facility_room_campus_code UNIQUE (campus_key, room_code),
    CONSTRAINT uq_facility_room_campus_section UNIQUE (campus_key, class_section_key),
    CONSTRAINT ck_facility_room_classroom_mapping CHECK (
        (room_type = 'Classroom' AND class_section_key IS NOT NULL)
        OR (room_type <> 'Classroom' AND class_section_key IS NULL)
    )
);

CREATE TABLE public.facility_room_closure (
    closure_key integer PRIMARY KEY,
    room_key integer NOT NULL REFERENCES public.facility_room (room_key),
    closure_date date NOT NULL,
    start_time time NOT NULL,
    end_time time NOT NULL,
    time_zone varchar(32) NOT NULL CHECK (time_zone = 'Europe/Amsterdam'),
    closure_status varchar(12) NOT NULL CHECK (closure_status = 'Planned'),
    closure_reason varchar(80) NOT NULL CHECK (
        closure_reason = 'Synthetic planned maintenance'
    ),
    CONSTRAINT ck_facility_room_closure_time CHECK (start_time < end_time)
);

COMMIT;
