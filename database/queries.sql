-- =====================================================================
-- WaterWatch - example queries (SQLite)
-- Values such as meter 1, site 1 or the dates are examples: replace them,
-- or in Python use placeholders:  conn.execute(sql, (meter_id, start, end))
-- Timestamps are ISO 8601 UTC text, so plain >= / < comparisons are correct.
-- =====================================================================


-- 1. Consumption history for a meter (feeds a Streamlit line chart) ----
SELECT timestamp, flow_rate AS flow_l_min, total_volume AS total_liters, source
FROM   readings
WHERE  meter_id = 1
  AND  timestamp >= '2026-11-26T00:00:00Z'
  AND  timestamp <  '2026-11-27T00:00:00Z'
ORDER  BY timestamp;


-- 2. All alerts of a site (all its meters), newest first ----------------
SELECT a.id, m.meter_name, a.alert_type, a.severity, a.status,
       a.detected_at, a.estimated_lost_volume AS lost_liters, a.description
FROM   alerts a
JOIN   water_meters m ON m.id = a.meter_id
WHERE  m.site_id = 1
ORDER  BY a.detected_at DESC;


-- 3. Daily water consumption per meter ---------------------------------
-- total_volume is a cumulative counter, so a day's consumption is the
-- difference between its last and first reading (NOT a sum of flow_rate).
-- Limitation: the volume between the last reading of a day and the first
-- of the next one is not counted (negligible with frequent readings).
-- If a counter reset is possible (device reboot), clean those rows first.
SELECT meter_id,
       date(timestamp)                           AS day,
       ROUND(MAX(total_volume) - MIN(total_volume), 1) AS consumption_liters,
       ROUND(MAX(flow_rate), 1)                  AS peak_flow_l_min
FROM   readings
GROUP  BY meter_id, date(timestamp)
ORDER  BY meter_id, day;


-- 4a. Meters with abnormal consumption: readings compared to thresholds --
-- (days where the peak flow or the daily volume exceeds the enabled threshold)
WITH daily AS (
    SELECT meter_id,
           date(timestamp)                      AS day,
           MAX(flow_rate)                       AS peak_flow,
           MAX(total_volume) - MIN(total_volume) AS daily_volume
    FROM   readings
    GROUP  BY meter_id, date(timestamp)
)
SELECT m.id AS meter_id, m.meter_name, d.day,
       ROUND(d.peak_flow, 1)    AS peak_flow,    t.max_flow_rate,
       ROUND(d.daily_volume, 1) AS daily_volume, t.max_daily_volume,
       d.peak_flow    > t.max_flow_rate         AS flow_exceeded,
       d.daily_volume > t.max_daily_volume      AS volume_exceeded
FROM   daily d
JOIN   thresholds   t ON t.meter_id = d.meter_id AND t.enabled = 1
JOIN   water_meters m ON m.id = d.meter_id
WHERE  d.peak_flow > t.max_flow_rate
   OR  d.daily_volume > t.max_daily_volume
ORDER  BY d.day DESC, m.id;

-- 4b. Meters that currently have unresolved alerts ----------------------
SELECT m.id AS meter_id, m.meter_name,
       COUNT(*)                          AS open_alerts,
       MAX(a.severity = 'CRITICAL')      AS has_critical,
       ROUND(SUM(COALESCE(a.estimated_lost_volume, 0)), 1) AS estimated_lost_liters
FROM   alerts a
JOIN   water_meters m ON m.id = a.meter_id
WHERE  a.status IN ('NEW', 'ACKNOWLEDGED')
GROUP  BY m.id, m.meter_name
ORDER  BY open_alerts DESC;


-- 5. Current CONFIRMED valve state (+ the latest requested command) -----
-- valves.valve_status is what the valve REALLY is; the last command is only
-- what was asked. If they differ, a command is still waiting or has failed.
SELECT v.id AS valve_id, v.valve_name, m.meter_name,
       v.valve_status          AS confirmed_state,
       v.last_status_update    AS confirmed_at,
       v.control_mode,
       lc.command              AS last_requested_command,
       lc.status               AS last_command_status,
       lc.requested_at         AS last_requested_at
FROM   valves v
JOIN   water_meters m ON m.id = v.meter_id
LEFT   JOIN valve_commands lc
       ON lc.id = (SELECT id FROM valve_commands
                   WHERE valve_id = v.id
                   ORDER BY requested_at DESC, id DESC LIMIT 1);


-- 6. History of valve commands (complete, newest first) -----------------
SELECT c.id, c.command, c.command_source, c.status,
       c.requested_at, c.sent_at, c.executed_at, c.error_message
FROM   valve_commands c
WHERE  c.valve_id = 1
ORDER  BY c.requested_at DESC, c.id DESC;


-- 7. Offline devices ----------------------------------------------------
-- Offline = flagged OFFLINE, never seen, or silent for more than 5 minutes.
SELECT d.id, d.device_uid, d.device_name, d.device_type, m.meter_name,
       d.connection_status, d.last_seen,
       ROUND((julianday('now') - julianday(d.last_seen)) * 24 * 60, 1) AS minutes_since_last_seen
FROM   devices d
JOIN   water_meters m ON m.id = d.meter_id
WHERE  d.connection_status = 'OFFLINE'
   OR  d.last_seen IS NULL
   OR  d.last_seen < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-5 minutes')
ORDER  BY d.last_seen;


-- ---------------------------------------------------------------------
-- Bonus: typical write operations
-- ---------------------------------------------------------------------

-- A. Queue a command (status defaults to PENDING; the valve is NOT touched)
-- INSERT INTO valve_commands (valve_id, command, command_source) VALUES (1, 'CLOSE', 'MANUAL');

-- B. The dispatcher sends it to the (virtual) ESP32
-- UPDATE valve_commands SET status = 'SENT', sent_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
-- WHERE id = :command_id AND status = 'PENDING';

-- C. On ESP32 confirmation: use confirm_valve_command() in database.py
--    (it updates the command AND the valve in one transaction).

-- D. Timeout: use expire_stale_commands() in database.py, or in SQL:
-- UPDATE valve_commands SET status = 'EXPIRED', error_message = 'No confirmation received within 30 seconds'
-- WHERE status = 'SENT' AND sent_at <= strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 seconds');

-- E. Close an alert as a false positive
-- UPDATE alerts SET status = 'FALSE_POSITIVE', resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
-- WHERE id = :alert_id;
