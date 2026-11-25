--| Question 6: Monthly Payroll Processing
-- Target: PostgreSQL 14+ with pg_cron.
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6;

-- (a) Tables
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month),
    CONSTRAINT ck_pay_month_first_day CHECK (pay_month = date_trunc('month', pay_month)::date)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- (c) Procedure: query FOR loop; any failure aborts the whole call (nothing is inserted)
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec     RECORD;
    v_net   NUMERIC;
    v_gross NUMERIC;
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month (%) must be the first day of a month', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(rec.employee_id);         -- raises on an invalid calculation
        v_gross := rec.basic_salary + rec.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING; -- existing rows stay unchanged
    END LOOP;
END;
$$;

-- (d) Trigger: log actual basic_salary changes only
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- Seed employees (active, then one leaves later)
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chanda Mwila',   9000.00, 1500.00, 1200.00, TRUE),
    ('Temwani Banda',  7500.00, 1000.00,  900.00, TRUE),
    ('Mutale Phiri',   6000.00,  800.00,  700.00, TRUE),
    ('Natasha Zulu',   8200.00, 1200.00, 1000.00, TRUE),   -- becomes inactive below
    ('Peter Tembo',    5000.00,  500.00,  600.00, FALSE);  -- inactive from the start

-- Two payroll months for the (then) active employees
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- Natasha leaves; her history must stay visible in the report
UPDATE employees SET active = FALSE WHERE employee_id = 4;
CALL pr_process_payroll(DATE '2026-11-01');                -- she is no longer included
CALL pr_process_payroll(DATE '2026-11-01');                -- rerun: nothing changes, no duplicates

-- Salary change test: audit row for a real change only
UPDATE employees SET basic_salary = 9500.00 WHERE employee_id = 1;   -- logged
UPDATE employees SET basic_salary = 9500.00 WHERE employee_id = 1;   -- same value: not logged
UPDATE employees SET allowance = 1600.00   WHERE employee_id = 1;    -- other column: not logged
SELECT * FROM salary_audit;                                           -- exactly 1 row

-- Existing payroll rows are unchanged by the raise (September still uses 9000 basic)
SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- Tests
SELECT fn_net_pay(1) AS net_pay_employee_1;     -- 9500 + 1600 - 1200 = 9900.00

DO $$
BEGIN
    BEGIN PERFORM fn_net_pay(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_process_payroll(DATE '2026-12-15');          -- not a month start
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_process_payroll(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;

-- Invalid employee calculation must fail the WHOLE call: make a negative net, run, check nothing was added.
BEGIN;
UPDATE employees SET deduction = 99999 WHERE employee_id = 3;   -- negative net for Mutale
DO $$
BEGIN
    CALL pr_process_payroll(DATE '2026-12-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;
SELECT COUNT(*) AS december_rows_should_be_0 FROM payroll WHERE pay_month = DATE '2026-12-01';
ROLLBACK;

-- (e) View: inner join keeps history even when the employee is now inactive
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
ORDER BY p.pay_month, e.full_name;

SELECT * FROM v_payroll_report;               -- Natasha appears for Sep and Oct

-- (f) Index for "all employees in one month".
-- The existing unique index is (employee_id, pay_month): its leading column is
-- employee_id, so it cannot be used efficiently to filter by pay_month alone.
-- This index is on pay_month only (different leading column, so it does not
-- duplicate it) and INCLUDEs the report columns so the query can be index-only.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month) INCLUDE (employee_id, gross_pay, net_pay);
ANALYZE payroll;

SET enable_seqscan = off;   -- demonstration only (table is tiny)
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on the 1st of every month, for the PREVIOUS month
-- (CREATE EXTENSION pg_cron; once)
SELECT cron.schedule(
    'q6_process_payroll_monthly',
    '0 2 1 * *',
    $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job definition
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_process_payroll_monthly';

-- Inspect run history (status, message, start/end times)
SELECT d.runid, d.jobid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'q6_process_payroll_monthly'
ORDER BY d.start_time DESC;

-- Remove the job if required:
-- SELECT cron.unschedule('q6_process_payroll_monthly');
