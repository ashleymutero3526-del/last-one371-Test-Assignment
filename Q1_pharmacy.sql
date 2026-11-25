-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Target: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1;

-- ---------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  40),
    ('Ibuprofen 200mg',   3.75,  25),
    ('Vitamin C 100mg',   1.50,  12);

-- ---------------------------------------------------------------
-- (b) Function
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- ---------------------------------------------------------------
-- (c) Procedure
-- All checks happen before any change; the row lock (FOR UPDATE)
-- prevents two sessions overselling. Any exception rolls back the call,
-- so an invalid sale leaves both tables unchanged.
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    SELECT unit_price, stock_qty
      INTO v_price, v_stock
      FROM medicines
     WHERE medicine_id = p_medicine_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity      -- deducted exactly once
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- ---------------------------------------------------------------
-- (d) Trigger: audit only real stock changes
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- ---------------------------------------------------------------
-- (a) continued: six valid sales loaded through the procedure
-- ---------------------------------------------------------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(2,  5, CURRENT_DATE - 2);
CALL pr_record_sale(3, 20, CURRENT_DATE - 1);
CALL pr_record_sale(4,  4, CURRENT_DATE - 1);
CALL pr_record_sale(1, 15, CURRENT_DATE - 1);
CALL pr_record_sale(4,  3, CURRENT_DATE);        -- Vitamin C drops to 5

SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM stock_audit ORDER BY audit_id;     -- 6 rows, one per sale

-- Test: function and invalid sales (each must fail and change nothing)
SELECT fn_sale_value(2, 3) AS value_of_3_amoxicillin;   -- 24.00
DO $$
BEGIN
    BEGIN PERFORM fn_sale_value(999, 1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_sale_value(1, 0);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_record_sale(2, 1000, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
SELECT medicine_id, stock_qty FROM medicines ORDER BY medicine_id;  -- unchanged

-- ---------------------------------------------------------------
-- (e) View
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(4, 2, CURRENT_DATE);         -- a further sale
SELECT * FROM v_low_stock;                        -- Vitamin C (3 left)

-- ---------------------------------------------------------------
-- (f) Index
-- Composite (medicine_id, sold_on): equality on medicine_id first, then
-- a range scan on sold_on inside that medicine's entries - an exact match
-- for "one medicine's sales in a date range", no sort needed.
-- ---------------------------------------------------------------
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);
ANALYZE sales;

-- Tiny tables favour a sequential scan; disable it only to demonstrate the index.
SET enable_seqscan = off;
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------
-- (g) Scheduled job (idempotent: upsert replaces, never adds)
-- ---------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);          -- rerun: no duplicate, no double count
SELECT * FROM daily_sales;

-- pg_cron (install once in the database that holds cron: CREATE EXTENSION pg_cron;)
-- 00:15 every day, processing the previous day
SELECT cron.schedule(
    'q1_refresh_sales_daily',
    '15 0 * * *',
    $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$
);
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q1_refresh_sales_daily';
