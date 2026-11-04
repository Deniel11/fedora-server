# Optional CrowdSec Integration

This repository supports an optional CrowdSec Security Engine integration
for the host-managed Nginx reverse proxy running directly on Fedora Server.

## Security model

The initial integration is detection-only.

- CrowdSec reads configured Nginx access logs.
- The Nginx collection provides relevant parsing and detection rules.
- This module does not install or enable an Nginx bouncer.
- This module does not create or change OPNsense firewall rules.
- Automatic IP blocking is not enabled.

Before enabling enforcement, validate the client IP address seen by Nginx,
trusted reverse-proxy settings, and the consequences of false positives.

## Installation

During the Nginx installation stage, the installer offers CrowdSec as an
optional component. Declining does not prevent Nginx installation. The choice
is saved in `/etc/fedora-server-setup/crowdsec-state.env`.

To install later:

```bash
sudo bash scripts/crowdsec.sh --install
```

The first installation uses the official CrowdSec repository bootstrap and
the Fedora DNF package manager. Review the downloaded bootstrap script and
repository trust requirements before approving installation.

## Dynamic Nginx log discovery

The integration reads the active Nginx configuration with `nginx -T`.
It discovers absolute file-based `access_log` targets and generates:

`/etc/crowdsec/acquis.d/fedora-server-nginx.yaml`

The generated file is managed by this integration. Unmanaged acquisition
files are not overwritten.

A systemd timer periodically checks the configured log paths. The generated
acquisition configuration can also enable periodic discovery of newly created
files, subject to the installed CrowdSec version's supported options.

The discovery handles common absolute file paths. It skips `access_log off`,
syslog targets, variables, and relative paths. Review the generated file if
your Nginx configuration uses advanced logging syntax.

## Management commands

```bash
sudo bash scripts/crowdsec.sh
sudo bash scripts/crowdsec.sh --install
sudo bash scripts/crowdsec.sh --refresh
sudo bash scripts/crowdsec.sh --status
sudo bash scripts/crowdsec.sh --remove
```

Removing the integration deletes its managed acquisition file, refresh timer,
service, and saved decision. It does not uninstall the CrowdSec package or
remove unrelated CrowdSec configuration.

## Verification

```bash
sudo nginx -T 2>&1 | grep -E '^[[:space:]]*access_log[[:space:]]+'
sudo cat /etc/crowdsec/acquis.d/fedora-server-nginx.yaml
sudo crowdsec -t
sudo systemctl status crowdsec
sudo systemctl status fedora-server-crowdsec-refresh.timer
sudo cscli metrics
sudo journalctl -u crowdsec --since "30 minutes ago"
sudo journalctl -u fedora-server-crowdsec-refresh.service
```

## Trusted proxy considerations

If traffic passes through OPNsense, a CDN, or another reverse proxy, confirm
that Nginx identifies the real client IP correctly. Only explicitly trusted
proxy addresses should be allowed to supply client IP headers.

Incorrect client-IP handling can cause CrowdSec to attribute requests to the
proxy rather than the original client, or to trust spoofed addresses.

## Enforcement

Do not enable a bouncer or firewall remediation until detection has been
validated against real traffic. Test administrative access and allowlists
before applying any blocking policy.

## Secrets and local state

Do not commit API keys, bouncer credentials, private IP allowlists, or other
server-specific secrets to this repository.
