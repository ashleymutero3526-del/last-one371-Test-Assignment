 | Question 3: Library Returns and Overdue Fines
-- Target: PostgreSQL 14+ with pg_cron.
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3;

-- (a) Tables
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER      NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE         NOT NULL,
    due_on        DATE         NOT NULL,
    returned_on   DATE         NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE      NULL,
    new_returned_on  DATE      NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Computer Networks');

-- Six loans, all inserted OPEN (returned_on NULL); returns are done by the procedure below.
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Chanda Mwila',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1: open, overdue 16 days
    (1, 'Temwani Banda', CURRENT_DATE - 10, CURRENT_DATE +  4),  -- 2: open, on time (not yet due)
    (2, 'Mutale Phiri',  CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 3: will be returned late
    (2, 'Natasha Zulu',  CURRENT_DATE - 20, CURRENT_DATE -  6),  -- 4: will be returned ON the due date
    (3, 'Peter Tembo',   CURRENT_DATE - 12, CURRENT_DATE +  2),  -- 5: open, on time
    (3, 'Grace Lungu',   CURRENT_DATE - 40, CURRENT_DATE - 26);  -- 6: open, overdue 26 days

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- earlier of the as-of date and the return date (when there is one)
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);          -- K2/day, minimum 0, due date itself = 0
END;
$$;

-- (c) Procedure: return date and final fine stored in ONE update.
-- fn_loan_fine reads the row as it was before the update (returned_on still NULL),
-- so passing p_returned_on as the as-of date gives the final fine.
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;

    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
     WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger: log only a real change of returned_on
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- Returned loans (after the trigger exists, so the audit table is populated)
CALL pr_return_loan(3, CURRENT_DATE - 8);    -- 3 days late -> K6
CALL pr_return_loan(4, CURRENT_DATE - 6);    -- returned on the due date -> K0

SELECT loan_id, due_on, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;  -- 2 rows

-- Function tests
SELECT fn_loan_fine(1, CURRENT_DATE) AS open_overdue_fine;       -- 32
SELECT fn_loan_fine(3, CURRENT_DATE) AS returned_loan_fine;      -- 6 (stops at return date)
SELECT fn_loan_fine(2, CURRENT_DATE) AS on_time_fine;            -- 0

DO $$
BEGIN
    BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(3, CURRENT_DATE);                  -- already returned
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(999, CURRENT_DATE);                -- unknown
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);            -- before borrowed_on
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- An update that does not change returned_on must NOT create an audit row
UPDATE loans SET borrower_name = 'Chanda M. Mwila' WHERE loan_id = 1;
SELECT COUNT(*) AS audit_rows_still_2 FROM loan_audit;

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;               -- loans 1 and 6

-- (f) Index: partial index containing only unreturned loans, keyed by book.
-- It is small (returned loans are excluded) and matches the search exactly.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;   -- demonstration only (table is tiny)
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job. A loan counts if it is overdue and still unreturned on p_as_of.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)   -- still unreturned on that date
      AND due_on < p_as_of                                 -- and past due
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);       -- rerun replaces the same snapshot_date
SELECT * FROM overdue_summary;               -- count 2, fine 32 + 52 = 84

-- 00:10 every day for CURRENT_DATE (CREATE EXTENSION pg_cron; once)
SELECT cron.schedule(
    'q3_refresh_overdue_daily',
    '10 0 * * *',
    $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$
);
