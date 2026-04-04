BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('stats_api_available','0');
COMMIT;
