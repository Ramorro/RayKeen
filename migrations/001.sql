BEGIN TRANSACTION;

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS profiles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol TEXT,
  name TEXT,
  address TEXT,
  port INTEGER,
  uuid_password TEXT,
  encryption TEXT,
  network TEXT,
  tls INTEGER DEFAULT 0,
  subscription_id INTEGER,
  active INTEGER DEFAULT 0,
  enabled INTEGER DEFAULT 1,
  last_tested TEXT,
  last_latency INTEGER,
  tags TEXT,
  notes TEXT,
  use_count INTEGER DEFAULT 0,
  exclude_from_autoselect INTEGER DEFAULT 0,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
  raw_uri TEXT
);

CREATE TABLE IF NOT EXISTS subscriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT,
  url TEXT,
  last_updated TEXT,
  profile_count INTEGER DEFAULT 0,
  profiles_added INTEGER DEFAULT 0,
  profiles_updated INTEGER DEFAULT 0,
  profiles_removed INTEGER DEFAULT 0,
  update_interval TEXT DEFAULT 'manual',
  enabled INTEGER DEFAULT 1,
  last_update_stats TEXT,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS routing_columns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT,
  outbound TEXT,
  profile_id INTEGER,
  "order" INTEGER DEFAULT 0,
  enabled INTEGER DEFAULT 1,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS routing_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  column_id INTEGER NOT NULL,
  type TEXT,
  value TEXT,
  comment TEXT,
  "order" INTEGER DEFAULT 0,
  enabled INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT,
  message TEXT,
  profile_id INTEGER,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS traffic_stats (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  profile_id INTEGER,
  bytes_in INTEGER DEFAULT 0,
  bytes_out INTEGER DEFAULT 0,
  latency INTEGER,
  snapshot_at TEXT DEFAULT CURRENT_TIMESTAMP,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_profiles_subscription_id ON profiles(subscription_id);
CREATE INDEX IF NOT EXISTS idx_profiles_protocol ON profiles(protocol);
CREATE INDEX IF NOT EXISTS idx_profiles_tags ON profiles(tags);
CREATE INDEX IF NOT EXISTS idx_profiles_raw_uri ON profiles(raw_uri);
CREATE INDEX IF NOT EXISTS idx_profiles_enabled ON profiles(enabled);
CREATE INDEX IF NOT EXISTS idx_routing_rules_column_id ON routing_rules(column_id);
CREATE INDEX IF NOT EXISTS idx_routing_rules_value ON routing_rules(value);
CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);
CREATE INDEX IF NOT EXISTS idx_traffic_stats_created_at ON traffic_stats(created_at);

INSERT OR IGNORE INTO settings(key, value) VALUES
 ('log_level','INFO'),
 ('ui_language','ru'),
 ('socks5_port','1080'),
 ('bind_interface','localhost');

COMMIT;
