# Nginx Site Analytics

The Loki + Grafana module provisions four shared dashboards: Nginx Analytics, Nginx Visitor Analytics, Nginx URL Analytics, and Nginx Security & Errors. It also generates a Visitor Analytics dashboard for each enabled application that has a managed Nginx configuration.

The shared dashboards include a website selector when site labels are available. Per-site dashboards are generated from application metadata by `generate-site-dashboards.sh`; the main installer refreshes these dashboards after an installation run when Loki + Grafana is installed.

Managed Nginx server blocks write access and error logs to `/var/log/nginx/<app-id>-access.log` and `/var/log/nginx/<app-id>-error.log`. Grafana Alloy labels these streams with the application ID as `site`. This provides per-site separation without requiring the hostname to be present in the access-log message.

The access-log queries assume the standard Nginx `combined` format. Visitor counts are based on client IP addresses and are only an approximation: NAT, shared networks, proxies, and bots can affect the results. This data does not identify a real-world person.

The Alloy source is configured to read newly discovered files from the beginning. Existing Alloy positions are preserved, so this change does not automatically rewind files that Alloy was already tracking. Historical logs are available only if they remain on disk and have been ingested into Loki. Review log volume and retention before attempting a manual backfill.

The installer does not change DNS records or make Grafana public. Per-site dashboards are generated after installation/reconfiguration; if a website is added outside the normal installer workflow, run `sudo ./install.sh --app loki-grafana` to refresh them.
