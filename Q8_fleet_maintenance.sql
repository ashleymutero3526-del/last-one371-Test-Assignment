--| Question 8: Transport Fleet Maintenance
-- Target: PostgreSQL 14+ with pg_cron.
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path TO q8;

-- (a) Tables
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL
);

-- Three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAK 1001', 12000,  5000),    -- 7000 km since service (due)
    ('BAL 2002',  8800,  5000),    -- 3800 km (not due)
    ('BAM 3003', 15000, 10000);    -- exactly 5000 km (due, boundary)

-- (d) Trigger (installed before trips are loaded)
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- lock the vehicle row so two trips cannot start from the same odometer
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer IS DISTINCT FROM v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer (%), got %',
                        v_current, NEW.start_odometer;
    END IF;
    IF NEW.end_odometer IS NULL OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % must be greater than start %',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;

    UPDATE vehicles                                  -- the only place the odometer moves
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_km INTEGER;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;
END;
$$;

-- (c) Procedure (does not touch vehicles; the trigger does that)
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- Six trips added through the procedure (each starts at the vehicle's current odometer)
CALL pr_record_trip(1, CURRENT_DATE - 6, 12000, 12150);
CALL pr_record_trip(1, CURRENT_DATE - 3, 12150, 12300);
CALL pr_record_trip(2, CURRENT_DATE - 5,  8800,  9000);
CALL pr_record_trip(2, CURRENT_DATE - 2,  9000,  9300);
CALL pr_record_trip(3, CURRENT_DATE - 4, 15000, 15100);
CALL pr_record_trip(3, CURRENT_DATE - 1, 15100, 15250);

SELECT * FROM trips ORDER BY trip_id;
SELECT vehicle_id, registration, current_odometer, last_service_odometer FROM vehicles ORDER BY 1;
-- expected current odometers: 12300, 9300, 15250

SELECT vehicle_id, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;  -- t, f, t

DO $$
BEGIN
    BEGIN PERFORM fn_service_due(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(999, CURRENT_DATE, 0, 10);          -- unknown vehicle
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12300, 12300);     -- end not greater
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12000, 12400);     -- wrong start (trigger)
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
          VALUES (1, CURRENT_DATE, 12300, 12200);                 -- direct SQL, bad mileage
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
SELECT current_odometer FROM vehicles WHERE vehicle_id = 1;       -- still 12300

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;      -- BAK 1001 and BAM 3003

-- (f) Index: equality on vehicle_id then a range on trip_on in one B-tree descent;
-- results come back already ordered by date.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;   -- demonstration only (table is tiny)
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
ORDER BY trip_on;
RESET enable_seqscan;

-- (g) Scheduled job: upsert alerts for due vehicles, delete alerts for vehicles no longer due
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service,
            flagged_on       = EXCLUDED.flagged_on;

    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (SELECT 1
                      FROM vehicles v
                      WHERE v.vehicle_id = sa.vehicle_id
                        AND v.current_odometer - v.last_service_odometer >= 5000);
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;         -- vehicles 1 and 3

-- Vehicle 1 is serviced: the alert must disappear on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;         -- only vehicle 3

-- Every Monday at 06:00 (CREATE EXTENSION pg_cron; once)
SELECT cron.schedule(
    'q8_refresh_service_alerts_weekly',
    '0 6 * * 1',
    $$CALL q8.pr_refresh_service_alerts()$$
);
