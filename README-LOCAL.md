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
