CREATE TABLE public.facility_room (
    room_key INTEGER PRIMARY KEY,
    campus_key INTEGER NOT NULL CHECK (campus_key BETWEEN 1 AND 5),
    room_code VARCHAR(16) NOT NULL UNIQUE,
    room_type VARCHAR(24) NOT NULL
        CHECK (room_type IN ('Classroom', 'ScienceLab', 'ArtStudio')),
    capacity INTEGER NOT NULL CHECK (capacity > 0),
    CONSTRAINT uq_facility_room_campus_code UNIQUE (campus_key, room_code)
);

CREATE TABLE public.facility_closure (
    closure_key INTEGER PRIMARY KEY,
    campus_key INTEGER NOT NULL CHECK (campus_key BETWEEN 1 AND 5),
    room_code VARCHAR(16) NOT NULL,
    closure_date DATE NOT NULL,
    closure_reason VARCHAR(60) NOT NULL,
    status VARCHAR(12) NOT NULL CHECK (status = 'Planned'),
    source_version VARCHAR(32) NOT NULL,
    UNIQUE (campus_key, room_code, closure_date),
    CONSTRAINT fk_facility_closure_room FOREIGN KEY (campus_key, room_code)
        REFERENCES public.facility_room (campus_key, room_code)
);
