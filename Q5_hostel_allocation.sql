--| Question 5: Hostel Room Allocation
-- Target: PostgreSQL 14+ with pg_cron.
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5;

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL,
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on))
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('2023001', 'Chanda Mwila'),
    ('2023002', 'Temwani Banda'),
    ('2023003', 'Mutale Phiri'),
    ('2023004', 'Natasha Zulu'),
    ('2023005', 'Peter Tembo'),
    ('2023006', 'Grace Lungu');

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),   -- will be full
    ('A102', 4),   -- will be partly occupied
    ('A103', 3);   -- will be empty (history only)

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active              -- ENDED rows are ignored
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- lock the room so two allocations cannot take the last bed together
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (d) Trigger: enforces the same rules for direct INSERT/UPDATE statements
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_self     INTEGER;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;                           -- ENDED rows occupy no bed
    END IF;

    IF TG_OP = 'UPDATE' THEN
        v_self := OLD.allocation_id;          -- exclude the row being updated
    ELSE
        v_self := NEW.allocation_id;
    END IF;

    -- lock the room row to serialise capacity checks
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;

    IF EXISTS (SELECT 1 FROM allocations a
               WHERE a.student_id = NEW.student_id
                 AND a.status = 'ACTIVE'
                 AND a.allocation_id <> v_self) THEN
        RAISE EXCEPTION 'Student % already has another ACTIVE allocation', NEW.student_id;
    END IF;

    IF (SELECT COUNT(*) FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id <> v_self) >= v_capacity THEN
        RAISE EXCEPTION 'Room % is at full capacity (%)', NEW.room_id, v_capacity;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- Seed allocations: full (A101), partly occupied (A102), empty (A103) + history
CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 50);   -- A101 now full (2/2)
CALL pr_allocate_room(3, 2, CURRENT_DATE - 40);   -- A102 1/4
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (4, 3, CURRENT_DATE - 200, CURRENT_DATE - 100, 'ENDED'),   -- history only
    (5, 1, CURRENT_DATE - 300, CURRENT_DATE - 120, 'ENDED');   -- history only

SELECT * FROM allocations ORDER BY allocation_id;
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY 1;  -- 0, 3, 3

-- Tests: every one must fail
DO $$
BEGIN
    BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);          -- full room
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(1, 2, CURRENT_DATE);          -- already ACTIVE
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(99, 2, CURRENT_DATE);         -- unknown student
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_free_beds(99);                           -- unknown room
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    -- direct SQL: trigger must block it too
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)
          VALUES (6, 1, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- Valid UPDATE of an existing ACTIVE row (self excluded from the count) must succeed
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

-- (e) View: LEFT JOIN keeps rooms with no allocations
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)             AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity
ORDER BY r.room_number;

SELECT * FROM v_room_occupancy;

-- (f) Index: partial index on ACTIVE rows only, keyed by room_id.
-- Only active rows count towards capacity, so the index stays small even as
-- ENDED history grows, and the capacity check/occupancy count reads it directly.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;   -- demonstration only (table is tiny)
EXPLAIN
SELECT allocation_id, student_id
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job: one row per (date, room), replaced on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id),
           r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                 -- rerun: same 3 rows, values replaced
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- 23:55 daily (CREATE EXTENSION pg_cron; once)
SELECT cron.schedule(
    'q5_refresh_occupancy_daily',
    '55 23 * * *',
    $$CALL q5.pr_refresh_occupancy()$$
);
