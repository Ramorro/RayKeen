BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('session_ttl_seconds','1800'),
 ('auth_login','admin');
COMMIT;
