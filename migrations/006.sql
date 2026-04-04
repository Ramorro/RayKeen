BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('low_ram_threshold_mb','50');
COMMIT;
