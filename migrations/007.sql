BEGIN TRANSACTION;
INSERT OR IGNORE INTO settings(key, value) VALUES
 ('doh_enabled','0'),
 ('doh_servers_order','https://dns.quad9.net/dns-query,https://dns.adguard-dns.com/dns-query,https://doh.dns.sb/dns-query,https://doh.comss.one/dns-query,https://dns.nextdns.io'),
 ('doh_custom_url',''),
 ('doh_fallback_timeout_sec','3'),
 ('doh_fakedns','0');
COMMIT;
