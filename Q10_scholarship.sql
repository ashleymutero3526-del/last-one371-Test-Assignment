--| Question 10: Scholarship Application Assessment
-- Eligible only if: age 18-25 inclusive AND monthly income <= K3,000 AND average mark >= 70.
-- Target: PostgreSQL 14+ with pg_cron.
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10;

-- (a) Tables
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('2023001', 'Chanda Mwila'),
    ('2023002', 'Temwani Banda'),
    ('2023003', 'Mutale Phiri');

-- Six PENDING applications across three students (qualifying, non-qualifying, boundaries)
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 1500.00, 80.00, CURRENT_DATE - 20, 'PENDING'),   -- 1 qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 15, 'PENDING'),   -- 2 qualifies: lowest age, highest income, lowest mark
    (2, 25, 2999.99, 70.00, CURRENT_DATE - 12, 'PENDING'),   -- 3 qualifies: highest age
    (2, 26, 1000.00, 90.00, CURRENT_DATE - 10, 'PENDING'),   -- 4 fails: age 26
    (3, 22, 3000.01, 85.00, CURRENT_DATE -  5, 'PENDING'),   -- 5 fails: income just above K3,000
    (3, 21, 2000.00, 69.99, CURRENT_DATE -  2, 'PENDING');   -- 6 fails: mark just below 70

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must not be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age    INTEGER;
    v_income NUMERIC;
    v_mark   NUMERIC;
    v_status VARCHAR(10);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status: %)',
                        p_application_id, v_status;
    END IF;

    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger: audit only real status changes
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- Tests: function boundaries and rejections
SELECT fn_scholarship_eligible(18, 3000, 70)    AS all_lower_boundaries_true,
       fn_scholarship_eligible(25, 3000, 100)   AS upper_age_true,
       fn_scholarship_eligible(26, 1000, 90)    AS age_26_false,
       fn_scholarship_eligible(20, 3000.01, 90) AS income_false,
       fn_scholarship_eligible(20, 1000, 69.99) AS mark_false;

DO $$
BEGIN
    BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- Assess one application manually
CALL pr_assess_application(1);                   -- APPROVED
SELECT application_id, status FROM applications WHERE application_id = 1;

DO $$
BEGIN
    BEGIN CALL pr_assess_application(1);         -- already assessed
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_assess_application(999);       -- unknown
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- No audit row when the status is not changed
UPDATE applications SET status = status WHERE application_id = 1;
SELECT COUNT(*) AS audit_rows_still_1 FROM decision_audit;

-- (g) Batch procedure (query FOR loop over PENDING rows only)
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'          -- completed applications are never touched
        ORDER BY application_id
        FOR UPDATE SKIP LOCKED
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();                 -- assesses applications 2-6
CALL pr_assess_pending();                 -- rerun: nothing pending, nothing changes
SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;     -- approved: 1,2,3 ; rejected: 4,5,6
SELECT * FROM decision_audit ORDER BY audit_id; -- exactly 6 rows (no duplicates after the rerun)

-- (e) View: approved only, income deliberately omitted
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- (f) Index: equality on status first, then range on submitted_on.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;   -- demonstration only (table is tiny)
EXPLAIN
SELECT application_id, student_id, average_mark
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- Every Monday at 08:00 (CREATE EXTENSION pg_cron; once)
SELECT cron.schedule(
    'q10_assess_pending_weekly',
    '0 8 * * 1',
    $$CALL q10.pr_assess_pending()$$
);
