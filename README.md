# Fedora Server Setup

A state-aware installer for a Fedora Server home-lab stack. It configures the host, network, Proxmox connection, Docker, Nginx reverse proxy, TLS certificates, and selected applications.

The installer is designed to be rerun: saved configuration and application state are stored outside the Git repository.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Installer workflow](#installer-workflow)
- [Domain and TLS modes](#domain-and-tls-modes)
- [GoDaddy DNS-01 setup](#godaddy-dns-01-setup)
- [Certificate renewal](#certificate-renewal)
- [Applications](#applications)
- [Update and maintenance](#update-and-maintenance)
- [Removal and data safety](#removal-and-data-safety)
- [Verification and troubleshooting](#verification-and-troubleshooting)
- [Runtime state and secrets](#runtime-state-and-secrets)
- [Repository layout](#repository-layout)

## Requirements

- Fedora Server.
- Root access (`sudo`).
- Network connectivity to download packages and repository archives.
- Docker and Nginx are installed/configured by the installer.
- For public ACME certificates: a domain you control and a GoDaddy DNS API Personal Access Token (PAT) with the required permissions.
- For local mode: local DNS records that resolve the service hostnames to the correct private IP addresses.

The custom-application wizard downloads repository archives without authentication. Repositories that require a login/token to download the archive are not supported by that wizard.

## Quick start

### Option A: Bootstrap directly from GitHub

The bootstrap script downloads the current `main` branch and installs the repository files under `/opt/fedora-server-setup`.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/Deniel11/fedora-server/main/bootstrap.sh \
  -o bootstrap.sh

chmod +x bootstrap.sh
sudo ./bootstrap.sh
sudo /opt/fedora-server-setup/install.sh
```

### Option B: Run from a local checkout

```bash
git clone https://github.com/Deniel11/fedora-server.git
cd fedora-server
sudo ./install.sh
```

On a first run, the installer guides you through domain/TLS configuration, application selection, and the initial installation plan.

## Installer workflow

The installer detects existing application installations and saved state.

When no installation or saved state is detected, it starts the first-time setup flow. When state already exists, the interactive menu offers:

```text
1) Update the existing installation
2) Modify saved settings and application selection
3) Install an application
4) Create a custom application
5) Update application source only
6) Remove one application
7) Remove the complete managed server package
8) Exit without changes
```

### Common commands

Run these from the repository directory, or replace `./install.sh` with `/opt/fedora-server-setup/install.sh` when using the bootstrap installation.

```bash
sudo ./install.sh
sudo ./install.sh --list
sudo ./install.sh --all
sudo ./install.sh --app joplin
sudo ./install.sh --update-source
sudo ./install.sh --help
```

- `--list` shows saved state and detected/available applications.
- `--all` selects all available application modules for an installation/update run.
- `--app NAME` selects one application module.
- `--update-source` stages source archives for custom applications; it does not deploy, rebuild, restart, or reload applications.
- `--help` displays the command-line usage.

The `--reconfigure` and `--reconfigure-domain` switches are also accepted by the script, but the current installer still enters its interactive flow. To change saved settings reliably, choose menu option **2**, then select the setting(s) to modify.

### Change saved settings

Select **2) Modify saved settings and application selection**. The settings submenu can change:

1. HTTPS/domain settings
2. Proxmox backend IP
3. Network settings
4. Application selection
5. GoDaddy PAT
6. GoDaddy DNS zones
7. All settings
8. Cancel

Only the selected settings are intended to be changed; the installer displays a plan before applying the operation.

The saved application selection is stored in:

```text
/etc/fedora-server-setup/selected-apps.env
```

## Domain and TLS modes

Domain settings are persisted in:

```text
/etc/fedora-server-setup/domain.env
```

The repository defaults in `config/domains.conf` use local `.home` names. In public mode, the installer derives service hostnames from the configured base domain and application prefix rather than requiring public names to be hard-coded into every application module.

### Local mode

Local mode uses a repository-managed private Certificate Authority (CA) for local TLS certificates. The CA certificate must be trusted on each client device for browsers and other clients to trust those certificates.

Configure local DNS so each service name resolves to the intended private IP address. Do not expose application ports directly to the Internet; the intended access path is through the configured Nginx reverse proxy.

### Public mode

Public mode uses Let's Encrypt and DNS-01 validation through GoDaddy. For example, with:

```text
Base domain: example.com
Application prefix: home
```

the application zone is:

```text
home.example.com
```

The shared certificate contains the zone apex and its wildcard:

```text
home.example.com
*.home.example.com
```

This covers one-level service names such as:

```text
fedora-server.home.example.com
proxmox.home.example.com
portainer.home.example.com
vault.home.example.com
joplin.home.example.com
forgejo.home.example.com
```

The exact hostnames depend on the configured domain and the applications selected for management.

DNS-01 validation does not require inbound Internet TCP ports 80 or 443 for the ACME challenge. That does not automatically make services reachable from outside your LAN: routing, DNS, firewall policy, and any desired remote-access method remain your responsibility.

### TLS settings for custom applications

The custom-application wizard lets you choose a TLS mode per application:

- **Public ACME certificate**: obtains a separate Let's Encrypt certificate for the custom app's canonical domain, primary domain, and configured aliases.
- **Local CA certificate**: uses the repository-managed private CA.
- **No certificate**: generates an HTTP-only Nginx configuration for that custom app.

A custom app can use ACME even when the global domain mode is local. GoDaddy credentials and DNS-zone configuration are still required for that app.

`APP_CERTIFICATE_ENABLED="false"` disables certificate handling for an application. The application must still have a matching Nginx configuration if it is to be reverse-proxied by this setup.

## GoDaddy DNS-01 setup

The DNS hook uses the GoDaddy Domains v3 DNS API:

```text
https://api.godaddy.com/v3/domains/zones/<zone>/dns-records
```

The GoDaddy PAT must have these scopes:

```text
domains.domain:read
domains.dns:update
```

During public-domain or custom-ACME configuration, the installer prompts for a PAT when a valid one is not already saved. Configure the registered DNS zones that are actually hosted on GoDaddy authoritative DNS. The hook chooses the most specific configured zone that matches the ACME domain, which allows more than one registered zone to be configured.

The PAT is stored on the server at:

```text
/etc/fedora-server-setup/godaddy.ini
```

The file is restricted to root access. Do not commit the PAT or any generated credential file to Git.

The DNS hook performs an API preflight and reports common failures:

- **HTTP 401**: the PAT is invalid, expired, revoked, or malformed.
- **HTTP 403**: the PAT lacks the required permissions.
- **HTTP 404**: check that the zone is hosted on GoDaddy authoritative DNS and is available to the authenticated account.

### Test GoDaddy DNS API access

Replace `example.com` with a registered zone you control and have configured in the installer:

```bash
sudo bash -c '
source /etc/fedora-server-setup/godaddy.ini
curl -fsS \
  -H "Authorization: Bearer ${GODADDY_PAT}" \
  -H "Accept: application/json" \
  "https://api.godaddy.com/v3/domains/zones/example.com/dns-records?type=TXT&name=_acme-challenge&page=1&pageSize=1"
'
```

A successful response confirms that this API request is accessible with the saved credentials; it does not by itself prove that every DNS zone or every certificate challenge is correctly configured.

## Certificate renewal

The certificate-processing stage uses the shared application list: applications saved in the selection plus already installed applications, without duplicate IDs. Stale or invalid IDs in the saved selection are skipped.

The Certbot renewal service and systemd timer are enabled only when the selected/installed application list includes an application that needs ACME certificates. When no managed application needs Certbot, the installer disables and removes the repository-managed renewal timer and service.

When enabled, the timer checks twice daily, around 03:17 and 15:17 local system time, with a randomized delay. A successful renewal triggers an Nginx reload.

Inspect the timer and service:

```bash
systemctl status fedora-server-certbot-renew.timer
systemctl status fedora-server-certbot-renew.service
systemctl list-timers fedora-server-certbot-renew.timer
```

List certificates and perform a renewal dry run:

```bash
sudo /opt/fedora-server-setup/certbot-venv/bin/certbot certificates
sudo /opt/fedora-server-setup/certbot-venv/bin/certbot renew --dry-run
```

These Certbot commands apply when the Certbot virtual environment exists. In local-only mode with no ACME certificates, the Certbot environment and renewal timer may not be present.

## Applications

The repository includes application modules under `apps/`. The installer discovers modules from their application configuration and helper scripts.

### Install an available application

Use the interactive menu and choose **3) Install an application**, or select an application with `--app` or `--all`. The saved selection is updated when an application is added to the managed installation.

### Create a custom application

Choose **4) Create a custom application**, or choose the custom-application option from the install menu. The wizard supports:

- Static-site deployment
- Docker Compose deployment
- Dockerfile deployment
- A primary domain, canonical domain, and optional aliases
- Public ACME, local CA, or no TLS certificate
- Optional health-check URL

The wizard downloads a public repository archive for the selected ref. It does not create or modify a Dockerfile for you. For Dockerfile deployment, provide a suitable Dockerfile in the repository.

### Update custom application source only

The source-only update stages the latest archive for the configured source ref. It deliberately does not deploy the downloaded code, rebuild the application, restart containers, or reload services.

```bash
sudo ./install.sh --update-source
```

## Update and maintenance

To update repository-managed files in a bootstrap installation:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
```

The updater downloads the current `main` branch and preserves the existing `config/domains.conf` file across the repository-file update. Runtime state, application data, credentials, and TLS material live outside the Git repository.

After a repository update, run the installer when required to reconcile services with the updated scripts and configuration.

## Removal and data safety

### Remove one application

Choose **6) Remove one application** from the existing-installation menu. The installer asks for confirmation and, where supported by the module, whether persistent Docker volumes/data should also be deleted. Read the prompts carefully before confirming; deleting volumes can permanently remove application data.

### Remove the complete managed server package

Choose **7) Remove the complete managed server package**. This removes repository-managed application containers, Nginx configuration, the Certbot renewal timer/service, managed TLS material, installer state, and the Certbot virtual environment.

The full removal does **not** remove Fedora, Docker packages, unrelated Docker data, router/LAN DNS settings, or the Git repository. The installer asks separately whether persistent Docker volumes belonging to managed applications should be deleted.

## Verification and troubleshooting

Run shell syntax checks from the repository root:

```bash
bash -n install.sh
bash -n scripts/*.sh
bash -n apps/*/*.sh
```

Review the working-tree diff before committing documentation or code changes:

```bash
git diff --check
git diff
```

Check Nginx and the saved installer state:

```bash
sudo ./install.sh --list
sudo nginx -t
systemctl status nginx
```

If public ACME certificates are expected, also check the GoDaddy PAT/scopes, the configured zone list, the certificate list, and the renewal timer. Do not assume the timer exists in a local-only installation.

Common checks:

- Confirm that each public certificate name is inside one of the configured GoDaddy zones.
- Confirm that the service hostname resolves to the correct address for the client network.
- Confirm that the configured app is selected or already installed, and that certificate handling is enabled for it.
- Confirm that Nginx configuration passes `nginx -t` before investigating an application-level health check.
- Do not publish the PAT, private keys, or `/etc/fedora-server-setup` credential files in issue reports.

## Runtime state and secrets

Important paths:

| Path | Purpose |
|---|---|
| `/etc/fedora-server-setup/domain.env` | Saved domain/TLS mode |
| `/etc/fedora-server-setup/selected-apps.env` | Saved application selection |
| `/etc/fedora-server-setup/godaddy.ini` | GoDaddy PAT; root-only file |
| `/etc/fedora-server-setup/godaddy-zones.conf` | Configured GoDaddy DNS zones |
| `/etc/fedora-server-setup/tls/` | Local CA and local certificate material |
| `/opt/fedora-server-setup/` | Installed repository scripts and Certbot virtual environment |
| `/opt/fedora-server-apps/` | Application runtime directories and generated Compose files |
| `/opt/fedora-server-sources/` | Downloaded custom application source archives |

Never commit passwords, tokens, private keys, databases, uploaded files, or other runtime application data to Git.

## Repository layout

```text
fedora-server/
├── apps/
├── config/
│   ├── domains.conf
│   ├── cockpit.conf
│   ├── fedora-server.nginx.conf
│   └── proxmox.nginx.conf
├── scripts/
│   ├── 00-common.sh
│   ├── 01-system.sh
│   ├── 02-proxmox.sh
│   ├── 03-network.sh
│   ├── 04-docker.sh
│   ├── 05-nginx.sh
│   ├── 40-certificates.sh
│   ├── 99-verify.sh
│   ├── custom-app-wizard.sh
│   ├── godaddy-dns-hook.sh
│   └── update-app.sh
├── bootstrap.sh
├── install.sh
├── update-repo.sh
├── README.md
└── README-EXTENDING.md
```

## Public access and dynamic DNS

Public domain mode keeps internet exposure opt-in per application. The machine-local selection is stored in `/etc/fedora-server-setup/public-access.env`, not in tracked application definitions, so two Fedora servers can use the same repository with different exposure choices. Applications not selected for public access remain available to the configured LAN/VPN ranges, while the public Nginx listener denies other clients.

Public applications have their configured primary domain, canonical domain, and aliases reconciled through one GoDaddy DDNS updater. The updater checks A and AAAA records every five minutes. It creates or updates a single matching record, leaves ambiguous multi-record names unchanged, and refuses to create A/AAAA records where a CNAME already exists. It leaves existing AAAA records unchanged when no globally routable IPv6 address is detected. Disabling public access does not delete DNS records automatically; it removes those domains from future DDNS updates and blocks non-LAN/VPN clients at Nginx.

Each public domain must match a configured GoDaddy DNS zone in `/etc/fedora-server-setup/godaddy-zones.conf`. In public mode, Cockpit and Proxmox are restricted to the configured LAN/VPN CIDRs. The default list covers common private IPv4 networks, loopback, and IPv6 ULA; review it if your VPN uses another range. Router TCP 80/443 forwarding remains a separate configuration step. Public-mode Nginx listeners include IPv6 as well as IPv4; IPv6 also requires the router/firewall to permit inbound TCP 80/443 to the server, because IPv6 commonly does not use IPv4-style NAT port forwarding.

