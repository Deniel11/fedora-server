# Fedora Server Home Services Setup

Automated, rerunnable setup for a fresh Fedora Server VM on Proxmox.

## What it installs

- static IPv4 configuration through NetworkManager (`nmcli`)
- Docker Engine + Compose plugin
- Nginx reverse proxy
- Cockpit
- Portainer CE
- Vaultwarden
- a local Certificate Authority and HTTPS certificates
- firewall rules for HTTP/HTTPS and Cockpit
- Proxmox IP configuration record for later AdGuard DNS setup

## DNS / hostnames

The intended names are:

| Name | Destination |
|---|---|
| `fedora-server.home` | Fedora server, Cockpit on `https://fedora-server.home:9090` |
| `portainer.home` | Fedora server, Nginx -> Portainer |
| `vault.home` | Fedora server, Nginx -> Vaultwarden |
| `proxmox.home` | Proxmox directly, using Proxmox's own HTTPS UI |

The Fedora Nginx server does **not** proxy Fedora/Cockpit or Proxmox.

DNS is deliberately not installed here. Later, configure these records in AdGuard:

```text
fedora-server.home -> FEDORA_STATIC_IP
portainer.home     -> FEDORA_STATIC_IP
vault.home         -> FEDORA_STATIC_IP
proxmox.home       -> PROXMOX_IP
```

Until AdGuard is ready, the services are still reachable by IP. For clean hostname-based HTTPS testing before DNS exists, use a temporary hosts entry or `curl --resolve`.

## First-install flow

The repository uses two separate stages:

1. `bootstrap.sh` downloads the repository without Git and installs the repository files under `/opt/fedora-server-setup`.
2. `install.sh` performs the actual Fedora Server setup.

The existing `install.sh` remains the main system installer.

### Bootstrap

Git is not required on the Fedora server.

From a fresh Fedora Server installation, run:

```bash
curl -fL https://raw.githubusercontent.com/Deniel11/fedora-server/main/bootstrap.sh \
  -o /tmp/bootstrap.sh

chmod +x /tmp/bootstrap.sh

sudo /tmp/bootstrap.sh
```

The bootstrap script:

* downloads the `main` branch as a tar archive
* stores the archive temporarily under `/tmp`
* extracts the repository into a temporary directory
* installs the repository under `/opt/fedora-server-setup`
* makes the repository scripts executable
* removes the temporary archive and extracted files

After bootstrap completes, run the main installer:

```bash
sudo /opt/fedora-server-setup/install.sh
```

If Fedora has pending system updates, `install.sh` handles the update-first workflow described above.

## Updating the repository

After the initial bootstrap, the repository can be updated without Git.

Run:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
```

The update script:

* downloads the latest `main` branch from GitHub
* stores the archive temporarily under `/tmp`
* extracts the new repository to a temporary directory
* updates the repository files under `/opt/fedora-server-setup`
* keeps runtime data and configuration outside the repository untouched
* removes the temporary files when finished

The existing installation is not removed before the update.

After updating, if the installer or setup scripts changed, run:

```bash
sudo /opt/fedora-server-setup/install.sh
```

The installer is designed to be rerunnable and will skip or preserve components that are already correctly configured.

### Complete workflow

Fresh server:

```text
Fresh Fedora Server
        |
        v
   bootstrap.sh
        |
        v
/opt/fedora-server-setup
        |
        v
     install.sh
        |
        v
Running home services
```

Later repository updates:

```text
GitHub main
     |
     v
update-repo.sh
     |
     v
/opt/fedora-server-setup
     |
     v
install.sh (when required)
```

The repository update mechanism does not require Git to be installed on the server.

## Download without Git

Git is **not required** on the Fedora server.

For a public GitHub repository:

```bash
curl -fL https://github.com/Deniel11/fedora-server/archive/refs/heads/main.tar.gz \
  -o /tmp/fedora-server.tar.gz

tar -xzf /tmp/fedora-server.tar.gz -C /tmp

cd /tmp/fedora-server-main

sudo ./install.sh
```

You can also use Git if you want to maintain the repository locally:

```bash
sudo dnf install -y git
git clone https://github.com/Deniel11/fedora-server.git
cd fedora-server
sudo ./install.sh
```

The installer itself does not depend on Git.

## Important: certificate trust

This project creates a local CA because `.home` is an internal domain.

Generated files are stored outside the Git repository under:

```text
/etc/fedora-server-setup/tls/
```

The CA private key never belongs in Git.

After installation, copy this file to each client device that should trust the services:

```text
/etc/fedora-server-setup/tls/ca.crt
```

Then install it as a trusted root CA on that client. The exact trust-store procedure depends on the client OS/browser.

Without importing the CA, browsers will correctly warn that the certificate is not trusted.

## IP access before DNS

HTTPS certificates contain both the configured hostname and the Fedora static IP as SANs.

Examples:

```text
https://FEDORA_STATIC_IP:9090
https://FEDORA_STATIC_IP
```

The hostname is still the preferred form once AdGuard is configured.

If an IP changes, rerun the installer. The certificate script detects the current IP and regenerates certificates when necessary.

## Script overview

| File | Purpose |
|---|---|
| `install.sh` | Main orchestrator and update-first gate |
| `scripts/00-common.sh` | Shared functions, paths, validation |
| `scripts/01-system.sh` | Base packages, firewall, system preparation |
| `scripts/02-network.sh` | Interactive static IPv4 configuration |
| `scripts/03-docker.sh` | Official Docker Engine repository + Docker/Compose |
| `scripts/04-nginx.sh` | Nginx installation and HTTPS reverse proxy |
| `scripts/05-cockpit.sh` | Cockpit installation and firewall |
| `scripts/10-portainer.sh` | Portainer Compose deployment |
| `scripts/20-vaultwarden.sh` | Vaultwarden Compose deployment |
| `scripts/30-proxmox.sh` | Interactive Proxmox IP record |
| `scripts/40-certificates.sh` | Local CA and service certificates |
| `scripts/99-verify.sh` | Final health checks and DNS instructions |

## Configuration

Edit:

```text
config/domains.conf
```

before installation if you want different internal hostnames.

The default configuration is:

```text
fedora-server.home
portainer.home
vault.home
proxmox.home
```

Do not put passwords, private keys, or tokens in this repository.

## Ports

| Service | Address |
|---|---|
| Nginx HTTP | TCP 80, redirects to HTTPS |
| Nginx HTTPS | TCP 443 |
| Cockpit | TCP 9090 |
| Portainer internal | `127.0.0.1:9443` |
| Vaultwarden internal | `127.0.0.1:8080` |
| Proxmox | Proxmox host, normally TCP 8006 |

Portainer and Vaultwarden are intentionally bound to localhost on the Fedora host. Clients should reach them through Nginx.

## Security notes

- Docker is installed from Docker's official Fedora repository.
- The installer does not add users to the `docker` group. Membership in that group is effectively root-level access.
- Nginx terminates HTTPS for Portainer and Vaultwarden.
- Cockpit uses the generated local-CA certificate directly.
- Proxmox keeps its own certificate and HTTPS configuration.
- The local CA private key is root-readable only.

## Updating containers

From the relevant directory:

```bash
cd /opt/fedora-server-setup/docker/portainer
sudo docker compose pull
sudo docker compose up -d
```

and:

```bash
cd /opt/fedora-server-setup/docker/vaultwarden
sudo docker compose pull
sudo docker compose up -d
```

Always read the application's release notes before major upgrades, especially for Vaultwarden.

## Backups

At minimum, back up:

```text
/etc/fedora-server-setup/tls/
/opt/fedora-server-setup/docker/vaultwarden/data/
```

The Vaultwarden data directory contains the actual application database and attachments.

## Troubleshooting

Nginx:

```bash
sudo nginx -t
sudo systemctl status nginx
sudo journalctl -u nginx -e
```

Docker:

```bash
sudo systemctl status docker
sudo docker ps
```

Portainer:

```bash
sudo docker compose -f /opt/fedora-server-setup/docker/portainer/compose.yml ps
```

Vaultwarden:

```bash
sudo docker compose -f /opt/fedora-server-setup/docker/vaultwarden/compose.yml ps
sudo docker logs vaultwarden
```

Cockpit certificate:

```bash
sudo /usr/libexec/cockpit-certificate-ensure --check
```

## ShellCheck

The scripts are intended to be ShellCheck-friendly:

```bash
shellcheck install.sh scripts/*.sh
```
