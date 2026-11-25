-- | Question 9: Farmer Cooperative Maize Deliveries
-- Rates: grade A K5/kg, B K4/kg, C K3/kg.
-- Target: PostgreSQL 14+ with pg_cron.
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path TO q9;

-- (a) Tables
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(10,2) NOT NULL,      -- always set by the trigger
    total_value  NUMERIC(12,2) NOT NULL,      -- always set by the trigger
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL,
    total_value   NUMERIC(12,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Chanda Mwila'),
    ('F002', 'Temwani Banda'),
    ('F003', 'Mutale Phiri');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$;

-- (d) Trigger: one pricing rule for procedure AND direct SQL
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade::text);        -- overrides anything supplied
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_delivery_pricing();

-- (c) Procedure: supplies only the basic fields; trigger fills rate and value
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     TEXT,
    p_weight    NUMERIC,
    p_date      DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight: %', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;
    PERFORM fn_maize_rate(p_grade);                 -- validates grade (NULL / unsupported)

    -- unit_rate and total_value are deliberately omitted: the BEFORE trigger sets them
    -- (NOT NULL is checked after BEFORE triggers run, so this is valid)
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- Seed: six deliveries, all grades, both payment states (loaded AFTER the trigger exists)
CALL pr_receive_delivery(1, 'A', 200.00, CURRENT_DATE - 3);
CALL pr_receive_delivery(1, 'B', 150.50, CURRENT_DATE - 2);
CALL pr_receive_delivery(2, 'C', 300.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A',  80.25, CURRENT_DATE - 1);
-- direct SQL (also priced by the trigger; the wrong rate supplied here is ignored)
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'B', 120.00, 99.00, 99999.00, CURRENT_DATE - 1, TRUE);
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
VALUES (1, 'C', 60.00, CURRENT_DATE - 3, TRUE);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 4);   -- more paid rows

SELECT * FROM deliveries ORDER BY delivery_id;       -- unit_rate / total_value are correct everywhere

SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
DO $$
BEGIN
    BEGIN PERFORM fn_maize_rate(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_maize_rate('D');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);       -- unknown farmer
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);        -- bad weight
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'Z', 10, CURRENT_DATE);        -- bad grade
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
          VALUES (1, 'A', 0, 5, 0, CURRENT_DATE);                    -- direct SQL, zero weight
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- (e) View: LEFT JOIN so farmers with no unpaid deliveries show 0
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS unpaid_amount
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name
ORDER BY f.farmer_number;

SELECT * FROM v_farmer_amount_due;

-- (f) Index: equality on farmer_id then a range on delivered_on in one descent.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;   -- demonstration only (table is tiny)
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job: upsert replaces totals
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);         -- rerun: replaced, not added
SELECT * FROM daily_purchases;

-- 01:30 daily for the previous day (CREATE EXTENSION pg_cron; once)
SELECT cron.schedule(
    'q9_refresh_purchases_daily',
    '30 1 * * *',
    $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$
);
