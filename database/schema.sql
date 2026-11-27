-- =====================================================================
-- WaterWatch - SQLite schema (9 tables)
-- Conventions:
--   * table / column names: lower_snake_case
--   * timestamps: TEXT, ISO 8601 in UTC, e.g. 2026-11-26T14:00:00Z
--   * booleans: INTEGER 0/1
--   * flow_rate in L/min (instantaneous), total_volume in liters (cumulative)
--   * foreign keys are ON DELETE RESTRICT: history is never lost by accident
-- Note: SQLite enforces foreign keys only when PRAGMA foreign_keys = ON is
-- set on EACH connection (database.py does this).
-- =====================================================================

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------
-- 1. clients
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clients (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT    NOT NULL CHECK (length(trim(name)) > 0),
    client_type    TEXT    NOT NULL CHECK (client_type IN ('HOTEL', 'WORKSHOP', 'FARM')),
    contact_name   TEXT,
    contact_email  TEXT    CHECK (contact_email IS NULL OR contact_email LIKE '_%@_%._%'),
    contact_phone  TEXT,
    created_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- ---------------------------------------------------------------------
-- 2. sites
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sites (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id    INTEGER NOT NULL REFERENCES clients(id) ON DELETE RESTRICT,
    name         TEXT    NOT NULL CHECK (length(trim(name)) > 0),
    address      TEXT,
    description  TEXT,
    created_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at   TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE (client_id, name)
);
CREATE INDEX IF NOT EXISTS idx_sites_client_id ON sites(client_id);

-- ---------------------------------------------------------------------
-- 3. water_meters
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS water_meters (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    site_id               INTEGER NOT NULL REFERENCES sites(id) ON DELETE RESTRICT,
    meter_name            TEXT    NOT NULL CHECK (length(trim(meter_name)) > 0),
    meter_code            TEXT    NOT NULL UNIQUE,
    location_description  TEXT,
    status                TEXT    NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'INACTIVE')),
    installation_date     TEXT    CHECK (installation_date IS NULL
                                         OR installation_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
    created_at            TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at            TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE (site_id, meter_name)
);
CREATE INDEX IF NOT EXISTS idx_water_meters_site_id ON water_meters(site_id);

-- ---------------------------------------------------------------------
-- 4. readings  (time series; the most queried table)
-- flow_rate    = instantaneous flow in L/min
-- total_volume = cumulative counter in liters (never "volume since last reading")
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS readings (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    meter_id      INTEGER NOT NULL REFERENCES water_meters(id) ON DELETE RESTRICT,
    timestamp     TEXT    NOT NULL CHECK (timestamp GLOB '????-??-??T??:??:??*Z'),
    flow_rate     REAL    NOT NULL CHECK (flow_rate >= 0),
    total_volume  REAL    NOT NULL CHECK (total_volume >= 0),
    source        TEXT    NOT NULL DEFAULT 'SIMULATION' CHECK (source IN ('SIMULATION', 'DEVICE')),
    created_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    -- one reading per meter per instant; this also creates the index
    -- (meter_id, timestamp) used by every history / chart / daily query
    UNIQUE (meter_id, timestamp)
);

-- ---------------------------------------------------------------------
-- 5. thresholds
-- A meter may keep old (disabled) configurations, but only ONE enabled one.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS thresholds (
    id                        INTEGER PRIMARY KEY AUTOINCREMENT,
    meter_id                  INTEGER NOT NULL REFERENCES water_meters(id) ON DELETE RESTRICT,
    max_flow_rate             REAL    NOT NULL CHECK (max_flow_rate > 0),          -- L/min
    max_daily_volume          REAL    NOT NULL CHECK (max_daily_volume > 0),       -- liters
    continuous_flow_duration  INTEGER NOT NULL CHECK (continuous_flow_duration > 0), -- minutes
    enabled                   INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    created_at                TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at                TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_thresholds_one_enabled_per_meter
    ON thresholds(meter_id) WHERE enabled = 1;

-- ---------------------------------------------------------------------
-- 6. alerts  (detection history, never deleted)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS alerts (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    meter_id               INTEGER NOT NULL REFERENCES water_meters(id) ON DELETE RESTRICT,
    alert_type             TEXT    NOT NULL CHECK (alert_type IN ('LEAK', 'HIGH_CONSUMPTION', 'FLOW_SPIKE', 'CONTINUOUS_FLOW')),
    severity               TEXT    NOT NULL CHECK (severity IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    description            TEXT    NOT NULL,
    detected_at            TEXT    NOT NULL CHECK (detected_at GLOB '????-??-??T??:??:??*Z'),
    estimated_lost_volume  REAL    CHECK (estimated_lost_volume IS NULL OR estimated_lost_volume >= 0), -- liters
    status                 TEXT    NOT NULL DEFAULT 'NEW'
                                   CHECK (status IN ('NEW', 'ACKNOWLEDGED', 'RESOLVED', 'FALSE_POSITIVE')),
    resolved_at            TEXT    CHECK (resolved_at IS NULL OR resolved_at GLOB '????-??-??T??:??:??*Z'),
    created_at             TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at             TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    -- an alert is "closed" (RESOLVED / FALSE_POSITIVE) exactly when resolved_at is set
    CHECK ((status IN ('RESOLVED', 'FALSE_POSITIVE')) = (resolved_at IS NOT NULL)),
    CHECK (resolved_at IS NULL OR resolved_at >= detected_at)
);
CREATE INDEX IF NOT EXISTS idx_alerts_meter_detected ON alerts(meter_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS idx_alerts_status         ON alerts(status);

-- ---------------------------------------------------------------------
-- 7. devices  (virtual ESP32 now, real ESP32 later)
-- connection_status is a convenience flag; last_seen is the source of truth
-- (the app should set OFFLINE when last_seen is too old).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS devices (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    meter_id           INTEGER NOT NULL REFERENCES water_meters(id) ON DELETE RESTRICT,
    device_uid         TEXT    NOT NULL UNIQUE,
    device_name        TEXT    NOT NULL CHECK (length(trim(device_name)) > 0),
    device_type        TEXT    NOT NULL DEFAULT 'VIRTUAL_ESP32' CHECK (device_type IN ('ESP32', 'VIRTUAL_ESP32')),
    connection_status  TEXT    NOT NULL DEFAULT 'OFFLINE' CHECK (connection_status IN ('ONLINE', 'OFFLINE')),
    last_seen          TEXT    CHECK (last_seen IS NULL OR last_seen GLOB '????-??-??T??:??:??*Z'),
    is_primary         INTEGER NOT NULL DEFAULT 1 CHECK (is_primary IN (0, 1)),
    created_at         TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at         TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    UNIQUE (id, meter_id)   -- target of the composite foreign key in valves
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_devices_one_primary_per_meter
    ON devices(meter_id) WHERE is_primary = 1;
CREATE INDEX IF NOT EXISTS idx_devices_status_last_seen ON devices(connection_status, last_seen);

-- ---------------------------------------------------------------------
-- 8. valves
-- valve_status = last CONFIRMED state (never just "the last command sent").
-- The requested state is the latest row of valve_commands.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS valves (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    meter_id            INTEGER NOT NULL REFERENCES water_meters(id) ON DELETE RESTRICT,
    device_id           INTEGER NOT NULL,
    valve_name          TEXT    NOT NULL CHECK (length(trim(valve_name)) > 0),
    valve_status        TEXT    NOT NULL DEFAULT 'UNKNOWN' CHECK (valve_status IN ('OPEN', 'CLOSED', 'UNKNOWN')),
    control_mode        TEXT    NOT NULL DEFAULT 'MANUAL'  CHECK (control_mode IN ('MANUAL', 'AUTOMATIC')),
    last_status_update  TEXT    CHECK (last_status_update IS NULL OR last_status_update GLOB '????-??-??T??:??:??*Z'),
    is_primary          INTEGER NOT NULL DEFAULT 1 CHECK (is_primary IN (0, 1)),
    created_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at          TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    -- the controlling device must belong to the SAME meter as the valve
    FOREIGN KEY (device_id, meter_id) REFERENCES devices(id, meter_id) ON DELETE RESTRICT,
    UNIQUE (meter_id, valve_name),
    -- a known state must come with the time it was confirmed
    CHECK (valve_status = 'UNKNOWN' OR last_status_update IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_valves_one_primary_per_meter
    ON valves(meter_id) WHERE is_primary = 1;
CREATE INDEX IF NOT EXISTS idx_valves_device ON valves(device_id, meter_id);

-- ---------------------------------------------------------------------
-- 9. valve_commands  (complete, append-only command history)
-- Lifecycle: PENDING -> SENT -> CONFIRMED | FAILED | EXPIRED
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS valve_commands (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    valve_id        INTEGER NOT NULL REFERENCES valves(id) ON DELETE RESTRICT,
    command         TEXT    NOT NULL CHECK (command IN ('OPEN', 'CLOSE')),
    command_source  TEXT    NOT NULL CHECK (command_source IN ('MANUAL', 'AUTOMATIC', 'SYSTEM')),
    status          TEXT    NOT NULL DEFAULT 'PENDING'
                            CHECK (status IN ('PENDING', 'SENT', 'CONFIRMED', 'FAILED', 'EXPIRED')),
    requested_at    TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                            CHECK (requested_at GLOB '????-??-??T??:??:??*Z'),
    sent_at         TEXT    CHECK (sent_at     IS NULL OR sent_at     GLOB '????-??-??T??:??:??*Z'),
    executed_at     TEXT    CHECK (executed_at IS NULL OR executed_at GLOB '????-??-??T??:??:??*Z'),
    error_message   TEXT,
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    -- lifecycle consistency
    CHECK (status <> 'PENDING' OR sent_at IS NULL),                    -- pending = not sent yet
    CHECK (status NOT IN ('SENT', 'CONFIRMED') OR sent_at IS NOT NULL),
    CHECK ((status = 'CONFIRMED') = (executed_at IS NOT NULL)),        -- only the ESP32 confirmation sets executed_at
    CHECK (status <> 'FAILED' OR error_message IS NOT NULL),
    CHECK (sent_at     IS NULL OR sent_at     >= requested_at),
    CHECK (executed_at IS NULL OR executed_at >= sent_at)
);
CREATE INDEX IF NOT EXISTS idx_valve_commands_valve_requested ON valve_commands(valve_id, requested_at DESC);
-- fast polling of the commands a device still has to handle / confirm
CREATE INDEX IF NOT EXISTS idx_valve_commands_open
    ON valve_commands(status, requested_at) WHERE status IN ('PENDING', 'SENT');

-- ---------------------------------------------------------------------
-- updated_at maintenance (SQLite has no ON UPDATE CURRENT_TIMESTAMP).
-- The WHEN clause lets an explicit updated_at in the UPDATE win.
-- ---------------------------------------------------------------------
CREATE TRIGGER IF NOT EXISTS trg_clients_updated_at AFTER UPDATE ON clients
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE clients SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_sites_updated_at AFTER UPDATE ON sites
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE sites SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_water_meters_updated_at AFTER UPDATE ON water_meters
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE water_meters SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_thresholds_updated_at AFTER UPDATE ON thresholds
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE thresholds SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_alerts_updated_at AFTER UPDATE ON alerts
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE alerts SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_devices_updated_at AFTER UPDATE ON devices
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE devices SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_valves_updated_at AFTER UPDATE ON valves
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
    UPDATE valves SET updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id = NEW.id;
END;
