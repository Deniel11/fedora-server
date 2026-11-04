# CrowdSec integration

This repository provides an optional CrowdSec integration for Nginx running directly on the Fedora Server host. CrowdSec reads Nginx access logs and evaluates them with the `crowdsecurity/nginx` collection.

The integration starts in detection-only mode. It does not install a remediation component or bouncer, configure OPNsense, change router rules, or enable automatic IP blocking. If a bouncer was already installed independently, it remains untouched and may continue enforcing its own decisions.

## Requirements

- Fedora Server with the repository-managed host Nginx service
- Root access
- Working Nginx configuration and readable Nginx access logs
- `curl`, `dnf`, `flock`, `awk`, and `sha256sum`

## Enable and manage

Run the repository installer:

```bash
sudo ./install.sh
```

Choose **9) Manage CrowdSec** from the existing-installation menu. During the Nginx stage, a one-time optional installation offer is also shown unless CrowdSec was already installed or previously declined.

The CrowdSec submenu can install or configure CrowdSec, refresh Nginx log discovery, show service status and metrics, or remove only this repository integration.

## What the integration changes

The Nginx templates explicitly write `combined` access logs for the Fedora Server and Proxmox virtual hosts. Managed application virtual hosts continue using the access logs created by the repository's application Nginx helper.

The integration reads `nginx -T`, extracts absolute `access_log` destinations, converts Nginx variables to glob patterns, and writes `/etc/crowdsec/acquis.d/fedora-server-nginx.yaml`. It ignores `off`, syslog, relative paths, and non-path destinations. The generated acquisition uses CrowdSec's file datasource, enables 30-second discovery polling for wildcard log patterns, and applies the Nginx parser labels.

A systemd timer checks for Nginx log configuration changes every five minutes. Unchanged acquisition configuration does not restart CrowdSec. A lock prevents a manual refresh and timer refresh from modifying the configuration simultaneously. The timer executes a managed runtime copy under `/opt/fedora-server-setup/` so it does not depend on the original checkout path.

If you are upgrading from the earlier repository integration, the module recognizes its prior root-owned state and generated ownership marker, then migrates those files to hash-based ownership metadata.

The module records hashes for files it owns. It refuses to overwrite an existing acquisition file or systemd unit unless its current content matches the previously recorded managed version. Removal uses the same ownership checks and retains files that have been changed or are not owned by this integration.

## Client IP address

CrowdSec decisions depend on the client IP recorded in Nginx access logs. Check the `remote_addr` field in the generated log entries and compare it with the address of a test client.

If traffic reaches Nginx through NAT, the source address may be preserved or translated depending on the network path. If an HTTP reverse proxy sits in front of Nginx, do not trust arbitrary `X-Forwarded-For` values. Configure Nginx real-IP handling only for explicitly known proxy addresses or CIDRs. Do not trust all sources or enable forwarded-header trust globally. This integration does not change real-IP or proxy trust settings.

## Install and supply-chain behavior

If CrowdSec is not already installed, the module downloads the official bootstrap script over HTTPS, displays its SHA-256 digest, and asks for explicit approval before executing it as root. The displayed digest is informational and is not presented as an independently authenticated vendor checksum. Fedora package signature verification remains enabled.

If CrowdSec is already installed, the module reuses it and does not replace its existing package configuration. It installs the Nginx collection only when that collection is absent.

## Verification

Run:

```bash
sudo ./install.sh
sudo nginx -t
sudo crowdsec -t
sudo cscli collections list
sudo cscli metrics
sudo systemctl status crowdsec
sudo systemctl status fedora-server-crowdsec-refresh.timer
sudo journalctl -u crowdsec --since today
```

The installer verification stage checks CrowdSec only when the integration state says it is installed. A declined or unused optional integration does not make the normal server verification fail.

Check that the configured log paths exist and are readable by CrowdSec. Confirm that `cscli metrics` shows log lines being read and parsed. If the log files are not being consumed, inspect CrowdSec service logs, Nginx log rotation behavior, and SELinux AVC records. Do not disable SELinux or make log files world-readable as a troubleshooting shortcut.

Example checks:

```bash
sudo ls -l /var/log/nginx/
sudo ausearch -m AVC -ts recent | grep -Ei 'crowdsec|nginx'
sudo cscli explain --file /var/log/nginx/fedora-server-access.log --type nginx
```

Use an existing log file for the `cscli explain` example. The exact file path depends on the active Nginx virtual hosts and enabled applications.

## Removal and retained data

Choose **4) Remove this repository integration** in the CrowdSec submenu, or confirm complete managed server package removal from the main installer.

Removal deletes only matching integration-owned acquisition and systemd files, the managed runtime script, log-target state, and integration state. It does not uninstall the CrowdSec RPM, delete CrowdSec databases or LAPI credentials, remove collections, remove independently installed bouncers, or alter unrelated CrowdSec configuration.

## Local validation

Run the repository checks before committing:

```bash
bash -n scripts/crowdsec.sh
bash tests/test-crowdsec-discovery.sh
git diff --check
```

A Fedora test VM is still required to validate package installation, systemd behavior, SELinux access, and real log ingestion. Static tests do not replace that integration test.
