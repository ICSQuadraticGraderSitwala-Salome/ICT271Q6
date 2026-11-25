DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- ============================================================
-- ICT371 - QUESTION 6: Employee Attendance and Monthly Pay
-- Pay = hours_worked * hourly_rate, only for status = 'present'
-- ============================================================

-- ------------------------------------------------------------
-- (a) DATABASE AND SEED DATA 
-- ------------------------------------------------------------
DROP TABLE IF EXISTS monthly_payroll, pay_audit, attendance, employees CASCADE;

CREATE TABLE employees (
  employee_id SERIAL PRIMARY KEY,
  employee_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL,
  hourly_rate NUMERIC(8,2) NOT NULL CHECK (hourly_rate > 0)
);

CREATE TABLE attendance (
  attendance_id SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  work_date DATE NOT NULL,
  hours_worked NUMERIC(4,2) NOT NULL CHECK (hours_worked >= 0 AND hours_worked <= 12),
  status VARCHAR(20) NOT NULL DEFAULT 'present'
    CHECK (status IN ('present', 'absent', 'leave')),
  UNIQUE (employee_id, work_date)
);

CREATE TABLE pay_audit (
  audit_id SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_rate NUMERIC(8,2) NULL,
  new_rate NUMERIC(8,2) NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE monthly_payroll (
  payroll_month VARCHAR(7) PRIMARY KEY,
  total_employees INT NOT NULL DEFAULT 0,
  total_hours NUMERIC(10,2) NOT NULL DEFAULT 0,
  total_pay NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO employees (employee_number, full_name, hourly_rate) VALUES
('EMP001', 'David Banda', 50.00),
('EMP002', 'Grace Zulu', 60.00),
('EMP003', 'Henry Mwale', 45.00);

-- ------------------------------------------------------------
-- (b) FUNCTION 
-- fn_employee_pay(p_employee_id, p_month 'YYYY-MM')
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_employee_pay(p_employee_id INT, p_month VARCHAR)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE v_pay NUMERIC(12,2);
DECLARE v_rate NUMERIC(8,2);
BEGIN
  IF p_month IS NULL THEN RAISE EXCEPTION 'Month is required, format YYYY-MM'; END IF;
  IF NOT EXISTS (SELECT 1 FROM employees WHERE employee_id = p_employee_id) THEN
    RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
  END IF;
  SELECT hourly_rate INTO v_rate FROM employees WHERE employee_id = p_employee_id;
  SELECT ROUND(COALESCE(SUM(hours_worked), 0) * v_rate, 2) INTO v_pay
  FROM attendance
  WHERE employee_id = p_employee_id
    AND TO_CHAR(work_date, 'YYYY-MM') = p_month
    AND status = 'present';
  RETURN COALESCE(v_pay, 0);
END; $$;

-- ------------------------------------------------------------
-- (c) PROCEDURE 
-- pr_record_attendance(p_employee_id, p_date, p_hours, p_status)
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_attendance(p_employee_id INT, p_date DATE, p_hours NUMERIC, p_status VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_employee_id IS NULL THEN RAISE EXCEPTION 'Employee ID is required'; END IF;
  IF p_date IS NULL THEN RAISE EXCEPTION 'Date is required'; END IF;
  IF p_date > CURRENT_DATE THEN RAISE EXCEPTION 'Cannot record future attendance: %', p_date; END IF;
  IF p_hours IS NULL OR p_hours < 0 OR p_hours > 12 THEN
    RAISE EXCEPTION 'Hours must be between 0 and 12';
  END IF;
  IF p_status NOT IN ('present', 'absent', 'leave') THEN
    RAISE EXCEPTION 'Invalid status: %', p_status;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM employees WHERE employee_id = p_employee_id) THEN
    RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
  END IF;
  IF EXISTS (SELECT 1 FROM attendance WHERE employee_id = p_employee_id AND work_date = p_date) THEN
    RAISE EXCEPTION 'Duplicate attendance: employee % already has record on %', p_employee_id, p_date;
  END IF;
  INSERT INTO attendance (employee_id, work_date, hours_worked, status)
  VALUES (p_employee_id, p_date, p_hours, p_status);
END; $$;

-- ------------------------------------------------------------
-- (d) TRIGGER 
-- AFTER UPDATE on employees -> pay_audit only if hourly_rate changed
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_pay_audit_fn()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.hourly_rate IS DISTINCT FROM NEW.hourly_rate THEN
    INSERT INTO pay_audit (employee_id, old_rate, new_rate, changed_at)
    VALUES (NEW.employee_id, OLD.hourly_rate, NEW.hourly_rate, NOW());
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_pay_audit ON employees;
CREATE TRIGGER trg_pay_audit
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_pay_audit_fn();

-- ------------------------------------------------------------
-- (a) CONTINUED: Seed 6 attendance rows THROUGH procedure
-- ------------------------------------------------------------
CALL pr_record_attendance(1, '2026-11-20', 8.00, 'present');
CALL pr_record_attendance(1, '2026-11-21', 8.00, 'present');
CALL pr_record_attendance(2, '2026-11-20', 8.00, 'present');
CALL pr_record_attendance(2, '2026-11-21', 0.00, 'absent');
CALL pr_record_attendance(3, '2026-11-20', 6.00, 'present');
CALL pr_record_attendance(3, '2026-11-21', 8.00, 'present');

-- Change 1 rate to test trigger
UPDATE employees SET hourly_rate = 55.00 WHERE employee_id = 1;

-- ------------------------------------------------------------
-- (e) VIEW 
-- v_absent_employees - all absent records
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW v_absent_employees AS
SELECT e.employee_number, e.full_name, a.work_date, a.status
FROM employees e
JOIN attendance a ON a.employee_id = e.employee_id
WHERE a.status = 'absent';

SELECT * FROM v_absent_employees;

-- ------------------------------------------------------------
-- (f) INDEX 
-- For an employee's attendance within a date range
-- ------------------------------------------------------------
CREATE INDEX idx_attendance_employee_date ON attendance (employee_id, work_date);

EXPLAIN ANALYZE
SELECT * FROM attendance
WHERE employee_id = 1 AND work_date BETWEEN '2026-11-20' AND '2026-11-30';

-- ------------------------------------------------------------
-- (g) SCHEDULED JOB
-- pr_refresh_payroll(p_month 'YYYY-MM') - replace row on rerun
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_payroll(p_month VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_month IS NULL THEN RAISE EXCEPTION 'Month is required'; END IF;
  INSERT INTO monthly_payroll (payroll_month, total_employees, total_hours, total_pay)
  SELECT p_month,
    COUNT(DISTINCT a.employee_id),
    COALESCE(SUM(a.hours_worked) FILTER (WHERE a.status = 'present'), 0),
    COALESCE(SUM(a.hours_worked * e.hourly_rate) FILTER (WHERE a.status = 'present'), 0)
  FROM attendance a
  JOIN employees e ON e.employee_id = a.employee_id
  WHERE TO_CHAR(a.work_date, 'YYYY-MM') = p_month
  ON CONFLICT (payroll_month) DO UPDATE
  SET total_employees = EXCLUDED.total_employees,
      total_hours = EXCLUDED.total_hours,
      total_pay = EXCLUDED.total_pay;
END; $$;

CALL pr_refresh_payroll('2026-11');
CALL pr_refresh_payroll('2026-11');

SELECT * FROM monthly_payroll;
SELECT * FROM pay_audit ORDER BY audit_id;
SELECT fn_employee_pay(1, '2026-11') AS david_pay;
SELECT fn_employee_pay(2, '2026-11') AS grace_pay;
SELECT fn_employee_pay(3, '2026-11') AS henry_pay;

-- Schedule: Daily at 00:40
-- SELECT cron.schedule('q6_refresh_payroll', '40 0 * * *', $$CALL pr_refresh_payroll(TO_CHAR(CURRENT_DATE, 'YYYY-MM'));$$);