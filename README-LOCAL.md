# Loki + Grafana Fix Bundle

This bundle is based on the current `main` branch of `Deniel11/fedora-server`. It does not write to GitHub.

## Fixes

- Public mode derives Grafana's hostname from saved `/etc/fedora-server-setup/domain.env`: `grafana.<APP_SUBDOMAIN>.<BASE_DOMAIN>`. With `home2` and `danielczank.eu`, this becomes `grafana.home2.danielczank.eu`.
- Local mode uses `GRAFANA_DOMAIN` from `config/domains.conf` (default `grafana.home`).
- Grafana is LAN/VPN-only in both local and public modes. The public-access wizard will remove `loki-grafana` from `PUBLIC_APPS` and skip its exposure prompt.
- Loki and Grafana host ports remain bound to localhost.
- Loki retention defaults to `30d`; configure it in `apps/loki-grafana/app.conf`.
- Persistent files and Grafana admin secret live under `/opt/fedora-server-data/loki-grafana`.

## Apply locally

From Git Bash, at the root of your local clone:

1. Back up your working tree. Review `git status --short` first.
2. Run `python3 loki-grafana-nginx-monitoring-fix/apply-local.py .`. It creates timestamped backups of `scripts/00-common.sh` and `scripts/public-access.sh`, and refuses to write unless all expected source fragments occur exactly once.
3. Review `apps/loki-grafana/app.conf` in this bundle and copy it over the repository version only after checking for local edits. Other application files in this bundle are included as reference snapshots; your repo already has them.
4. Validate with:

   ```bash
   bash -n scripts/00-common.sh scripts/public-access.sh apps/loki-grafana/install.sh apps/loki-grafana/verify.sh
   git diff --check
   git diff
   ```

5. Test `sudo ./install.sh --list` first and inspect that the app domain is correct before installing or reconfiguring.

This is a source-code fix, not a DNS management change. It does not create, delete, or alter DNS records. Test on the Fedora host before relying on it in production.

## Nginx Analytics dashboard

The Loki + Grafana module now provisions an editable `Nginx Analytics` dashboard automatically. It includes request rate, approximate active client IPs, transferred data rate, HTTP status-code trends, total requests, and total transferred bytes for the selected time range.

The dashboard parses the standard Nginx combined access-log format. If your Nginx `log_format` differs, update the LogQL `pattern` expressions in `apps/loki-grafana/provisioning/dashboards/nginx-analytics.json`. Visitor counts are approximate unique client IPs, not a cookie-based unique-human count; reverse proxies and NAT can affect this metric.

To apply the dashboard to an existing installation, apply the source changes locally, then re-run the app installer/reconfiguration according to the repository's normal workflow. The installer copies the dashboard provisioning files to the app runtime directory; restart/recreate Grafana for provisioning to be loaded. Back up the repository and review `git diff` before applying.

## Nginx Visitor Analytics dashboard

The module also provisions a separate `Nginx Visitor Analytics` dashboard. It includes top client IPs, most requested URI paths, request trends by IP and URL, recent detailed access-log entries, HTTP methods, referrers, and user-agent strings.

The queries assume the standard Nginx combined access-log format and the `job="nginx", log_type="access"` labels. Visitor counts are IP-based approximations: NAT, shared networks, reverse proxies, and bots can affect the results. If the Nginx log format differs, adjust the LogQL `pattern` expressions in `apps/loki-grafana/provisioning/dashboards/nginx-visitor-analytics.json`.

Only logs ingested into Loki can be queried. The current Alloy configuration uses `tail_from_end = true`, so existing log files may not be backfilled automatically. Changing that behavior requires a deliberate review of log volume, Alloy positions, and retention before restarting collection.
