-- | Question 7: Water Meter Readings and Billing
-- Tariff: first 10 units K5 each, units above 10 K8 each. Zero units = K0.
-- Target: PostgreSQL 14+ with pg_cron.
DROP SCHEMA IF EXISTS q7 CASCADE;
CREATE SCHEMA q7;
SET search_path TO q7;

-- (a) Tables
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_reading_cust_month UNIQUE (customer_id, reading_month),
    CONSTRAINT ck_reading_month_start CHECK (reading_month = date_trunc('month', reading_month)::date)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(10,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(10,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12,2) NOT NULL
);

-- (d) Trigger first, so even the seed data is validated
CREATE OR REPLACE FUNCTION trg_fn_reading_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;       -- raising aborts the statement, so the bad row is never stored
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_reading_check();

INSERT INTO customers (full_name) VALUES
    ('Chanda Mwila'), ('Temwani Banda'), ('Mutale Phiri');

-- Six readings: zero, exactly 10, and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00),   -- 0 units
    (1, DATE '2026-10-01', 100.00, 110.00),   -- exactly 10 units
    (2, DATE '2026-09-01',  50.00,  65.00),   -- 15 units
    (2, DATE '2026-10-01',  65.00,  90.00),   -- 25 units
    (3, DATE '2026-09-01',  10.00,  14.00),   -- 4 units
    (3, DATE '2026-10-01',  14.00,  34.00);   -- 20 units

-- (b) Function
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must be a non-negative number)', p_units;
    END IF;

    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_units NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT current_reading - previous_reading INTO v_units
    FROM readings WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;

-- Generate bills (some overdue, some not yet due)
CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 35);
CALL pr_generate_bill(4, CURRENT_DATE - 5);
CALL pr_generate_bill(5, CURRENT_DATE + 10);
CALL pr_generate_bill(6, CURRENT_DATE + 15);

-- Some payments: bill 3 paid in full, bill 4 part-paid
UPDATE bills SET amount_paid = charge WHERE bill_id = 3;
UPDATE bills SET amount_paid = 50     WHERE bill_id = 4;

SELECT fn_water_charge(0)  AS zero_units,    -- 0.00
       fn_water_charge(10) AS ten_units,     -- 50.00
       fn_water_charge(15) AS fifteen_units, -- 50 + 40 = 90.00
       fn_water_charge(25) AS twentyfive;    -- 50 + 120 = 170.00
SELECT * FROM bills ORDER BY bill_id;

-- Failure tests
DO $$
BEGIN
    BEGIN PERFORM fn_water_charge(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_water_charge(-1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_generate_bill(999, CURRENT_DATE);            -- unknown reading
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_generate_bill(1, CURRENT_DATE);              -- already billed
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
          VALUES (1, DATE '2026-11-01', 200, 150);             -- trigger must reject
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
SELECT COUNT(*) AS readings_still_6 FROM readings;

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;     -- bill 2 (50.00) and bill 4 (120.00); zero-charge and paid bills excluded

-- (f) Index: partial index over unpaid bills only, ordered by due date.
-- Overdue searches are range scans on due_on restricted to unpaid bills; paid
-- bills (the vast majority over time) are never in the index, so it stays small.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;   -- demonstration only (table is tiny)
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;          -- replace, never add
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                       -- rerun: same total
SELECT * FROM receivable_snapshot;

-- 00:30 daily (CREATE EXTENSION pg_cron; once)
SELECT cron.schedule(
    'q7_refresh_receivables_daily',
    '30 0 * * *',
    $$CALL q7.pr_refresh_receivables()$$
);
