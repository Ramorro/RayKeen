BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('routing_enabled','1');
COMMIT;
