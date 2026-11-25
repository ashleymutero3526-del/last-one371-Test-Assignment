--| Question 4: Clinic Appointment Scheduling
-- Target: PostgreSQL 14+ with pg_cron.
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4;

-- (a) Tables
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

-- (d) Trigger (created before seeding so even the seed data is protected).
-- BEFORE INSERT OR UPDATE: reject a clash with another NON-cancelled appointment.
CREATE OR REPLACE FUNCTION trg_fn_slot_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_self INTEGER;
BEGIN
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;                       -- a cancelled row occupies no slot
    END IF;

    -- exclude the row being changed (on UPDATE); on INSERT use the new row's own id
    IF TG_OP = 'UPDATE' THEN
        v_self := OLD.appointment_id;
    ELSE
        v_self := NEW.appointment_id;
    END IF;

    -- serialise concurrent bookings of the same doctor/day/slot
    PERFORM pg_advisory_xact_lock(
        hashtext(NEW.doctor_id::text || '|' || NEW.appointment_day::text || '|' || NEW.slot_time::text));

    IF EXISTS (SELECT 1
               FROM appointments a
               WHERE a.doctor_id       = NEW.doctor_id
                 AND a.appointment_day = NEW.appointment_day
                 AND a.slot_time       = NEW.slot_time
                 AND a.status         <> 'CANCELLED'
                 AND a.appointment_id <> v_self) THEN
        RAISE EXCEPTION 'Slot clash: doctor % already has an appointment on % at %',
                        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_slot_clash();

-- Seed data
INSERT INTO patients (full_name) VALUES
    ('Chanda Mwila'), ('Temwani Banda'), ('Mutale Phiri');
INSERT INTO doctors (full_name) VALUES
    ('Dr. Zulu'), ('Dr. Tembo'), ('Dr. Lungu');

-- Six appointments, none violating the slot rule (some for today, some past/future)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE - 1, '12:00', 'CANCELLED'),
    (3, 3, CURRENT_DATE + 1, '10:00', 'BOOKED');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count          -- COUNT returns 0 when the day has no bookings
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or NULL', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    -- clash detection is done by trigger trg_appointments_clash
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Tests
SELECT fn_daily_load(1, CURRENT_DATE)     AS dr1_today;        -- 2
SELECT fn_daily_load(3, CURRENT_DATE - 1) AS cancelled_ignored; -- 0
SELECT fn_daily_load(1, CURRENT_DATE + 30) AS no_bookings;      -- 0

CALL pr_book_appointment(2, 3, CURRENT_DATE + 2, '11:00');      -- valid

DO $$
BEGIN
    BEGIN PERFORM fn_daily_load(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');       -- clash
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');   -- past date
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');   -- bad slot
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '09:00');  -- unknown patient
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- UPDATE clash test: moving appointment 1 onto Dr. Zulu's 10:00 slot must fail,
-- but "updating" appointment 1 without changing its slot must succeed (self excluded).
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 1;     -- OK
DO $$
BEGIN
    UPDATE appointments SET slot_time = '10:00' WHERE appointment_id = 1;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- (e) View: only what the front desk needs - no phone/ID/other patient data
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time, d.full_name;

SELECT * FROM v_today_appointments;

-- (f) Index: non-unique (a doctor has up to 4 rows per day, and cancelled rows may repeat a slot).
-- Equality on both columns; appointment_day first so one day's rows are adjacent,
-- doctor_id second narrows to a single doctor.
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;   -- demonstration only (table is tiny)
EXPLAIN
SELECT appointment_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun replaces the row
SELECT * FROM clinic_summary;                       -- 0 booked, 1 attended, 1 cancelled

-- 01:00 daily for the previous day (CREATE EXTENSION pg_cron; once)
SELECT cron.schedule(
    'q4_refresh_clinic_summary_daily',
    '0 1 * * *',
    $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$
);
