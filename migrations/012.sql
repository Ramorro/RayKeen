BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('backup_keep_count','3');
COMMIT;
