BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('geo_mode','auto'),
 ('geo_update_interval_days','1'),
 ('geoip_url','https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'),
 ('geosite_url','https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat'),
 ('geo_last_updated','');
COMMIT;
