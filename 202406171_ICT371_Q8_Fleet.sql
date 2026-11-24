-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL
-- Service is due when current_odometer - last_service_odometer >= 5000 km.

DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path = q8_fleet, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) NOT NULL UNIQUE,
    current_odometer      INTEGER NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
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

-- Starting positions; the six trips below move them to 2000 / 5200 / 5000 km since service.
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1001 ZM', 10000,  9500),    -- will end 2000 km since service  (not due)
    ('ABC 1002 ZM', 20000, 15500),    -- will end 5200 km since service  (due)
    ('ABC 1003 ZM',  6000,  3000);    -- will end exactly 5000 km        (due: boundary)

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_cur INTEGER;
    v_svc INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_cur, v_svc
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    RETURN (v_cur - v_svc) >= 5000;
END;
$$;

/* ===================== (c) Procedure ===================== */
-- The procedure only validates and inserts the trip; the TRIGGER updates the odometer.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'trip date, start and end odometer must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

/* ===================== (d) Trigger ===================== */
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_current INTEGER;
BEGIN
    -- Lock the vehicle row so two trips cannot both start from the same odometer value.
    SELECT current_odometer INTO v_current FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end (%) must exceed start (%)', NEW.end_odometer, NEW.start_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer (%), got %', v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;  -- once per trip
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

/* ---- (a) continued: six trips added through the procedure, after the trigger exists ---- */
CALL pr_record_trip(1, CURRENT_DATE - 20, 10000, 10800);
CALL pr_record_trip(1, CURRENT_DATE - 10, 10800, 11500);
CALL pr_record_trip(2, CURRENT_DATE - 18, 20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE -  8, 20300, 20700);
CALL pr_record_trip(3, CURRENT_DATE - 15, 6000,  7000);
CALL pr_record_trip(3, CURRENT_DATE -  5, 7000,  8000);

SELECT * FROM vehicles ORDER BY vehicle_id;   -- odometers 11500 / 20700 / 8000
SELECT vehicle_id, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1;   -- f, t, t

-- Rejections
DO $$ BEGIN PERFORM fn_service_due(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 11500, 11500);   -- end not greater than start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 11000, 11200);   -- wrong starting odometer
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
-- Direct SQL is protected by the trigger too
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer) VALUES (1, CURRENT_DATE, 11500, 11000);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT current_odometer AS v1_odometer_unchanged FROM vehicles WHERE vehicle_id = 1;   -- 11500

/* ===================== (e) View ===================== */
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;   -- vehicles 2 and 3

/* ===================== (f) Index ===================== */
-- Justification: "one vehicle's trips in a date range" = equality on vehicle_id + range on
-- trip_on. A composite B-tree (vehicle_id, trip_on) goes straight to that vehicle and reads
-- only the requested dates in order, instead of scanning every trip in the fleet.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- Insert or update one alert for every vehicle that is due (original flagged_on is kept).
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

    -- Remove alerts for vehicles that are no longer due (e.g. after a service).
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                      WHERE v.vehicle_id = sa.vehicle_id
                        AND v.current_odometer - v.last_service_odometer >= 5000);
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every Monday at 06:00 (pg_cron time zone).
SELECT cron.schedule('q8_refresh_service_alerts_weekly', '0 6 * * 1',
                     $$CALL q8_fleet.pr_refresh_service_alerts()$$);

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();            -- rerun: still one alert per due vehicle
SELECT * FROM service_alerts ORDER BY vehicle_id;      -- vehicles 2 (5200) and 3 (5000)

-- Vehicle 2 gets serviced -> its alert disappears on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;      -- only vehicle 3 remains
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q8_refresh_service_alerts_weekly';
