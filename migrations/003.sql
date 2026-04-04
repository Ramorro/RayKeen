BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('subscription_user_agent','RayKeen/0.1'),
 ('subscription_timeout_sec','20');
COMMIT;
