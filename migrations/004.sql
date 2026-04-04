BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('socks5_port','1080'),
 ('bind_interface','localhost');
COMMIT;
