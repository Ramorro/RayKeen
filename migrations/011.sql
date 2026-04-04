BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('autoselect_enabled','0'),
 ('autoselect_protocol',''),
 ('autoselect_tag',''),
 ('autoselect_crash_threshold','3');
COMMIT;
