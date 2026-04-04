BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('test_method','http204'),
 ('latency_green_ms','200'),
 ('latency_yellow_ms','500');
COMMIT;
