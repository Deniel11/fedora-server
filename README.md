# Fedora Server Setup

Automated setup and configuration for a Fedora Server used as a small home-lab infrastructure server.

## Domain and HTTPS modes

The installer stores the selected domain/TLS mode in `/etc/fedora-server-setup/domain.env`.

### Local mode

The default remains the existing `.home` layout and a private local CA.

### Public domain mode

Example configuration:

```text
Base domain: danielczank.eu
Application subdomain: home
```

Resulting names:

```text
https://fedora-server.home.danielczank.eu
https://proxmox.home.danielczank.eu
https://portainer.home.danielczank.eu
https://vault.home.danielczank.eu
https://joplin.home.danielczank.eu
```

Public mode obtains publicly trusted Let's Encrypt certificates automatically with ACME DNS-01. No client-side CA installation is required and the Fedora server does not need to expose TCP 80 to the Internet.

## Required DNS setup for public certificates

The registered domain must be managed by GoDaddy DNS (or the DNS zone must be delegated there), because the installer uses the GoDaddy DNS API to create temporary `_acme-challenge` TXT records for validation.

The application names still need to resolve to the Fedora Server from your LAN. This can be handled by the router/local DNS. Public DNS does not need to point these names to the home public IP for certificate validation.

For example, your local DNS can resolve:

```text
fedora-server.home.danielczank.eu -> Fedora Server private IP
proxmox.home.danielczank.eu       -> Proxmox IP
portainer.home.danielczank.eu     -> Fedora Server private IP
vault.home.danielczank.eu         -> Fedora Server private IP
joplin.home.danielczank.eu        -> Fedora Server private IP
```

No TCP 80 port-forward is required for certificate issuance or renewal. TCP 443 is only required if you want to access the services from outside your LAN.

### GoDaddy API credentials

Public mode asks for a GoDaddy API key and secret on the first configuration. They are stored only on the Fedora server at:

```text
/etc/fedora-server-setup/godaddy.ini
```

The file is owned by root and has mode `600`. The credentials are used by Certbot to create and remove the DNS TXT records required by DNS-01. The repository never stores them.

The installer uses the `certbot-dns-godaddy` plugin and waits 120 seconds for DNS propagation before validation. DNS-01 is also the ACME validation method that supports wildcard certificates.

## Installation

```bash
git clone https://github.com/Deniel11/fedora-server.git
cd fedora-server
chmod +x install.sh bootstrap.sh update-repo.sh scripts/*.sh
sudo ./install.sh
```

To install everything:

```bash
sudo ./install.sh --all
```

To change the saved domain/TLS configuration:

```bash
sudo ./install.sh --reconfigure-domain
```

For a full application reconciliation after a domain change:

```bash
sudo ./install.sh --all --reconfigure
```

## Updating an existing server

```bash
sudo /opt/fedora-server-setup/update-repo.sh
sudo /opt/fedora-server-setup/install.sh --all --reconfigure
```

## DNS responsibility

The repository manages the Fedora Server side only. DNS remains outside the installer.

For local mode, local DNS should point the `.home` names to the appropriate private IPs.

For public mode, the registered domain must be managed through GoDaddy DNS (or delegated to GoDaddy DNS) so the installer can automate ACME DNS-01 validation. No inbound TCP 80 is required.

## TLS certificate locations

Local mode:

```text
/etc/fedora-server-setup/tls/
```

Public mode:

```text
/etc/letsencrypt/live/<hostname>/
```

Public certificates are checked/renewed automatically by a systemd timer installed by the Nginx stage. Renewal also uses DNS-01 and therefore does not require an HTTP listener on port 80.

## Safety and persistence

* Application data is stored outside the repository.
* Domain configuration and GoDaddy credentials are stored outside the repository.
* Docker application data is not removed during domain changes.
* Managed Nginx files are regenerated from the repository.
* Certificates are renewed before expiry.

## Repository structure

```text
fedora-server/
├── apps/
├── config/
├── scripts/
│   ├── 00-common.sh
│   ├── 01-system.sh
│   ├── 02-proxmox.sh
│   ├── 03-network.sh
│   ├── 04-docker.sh
│   ├── 05-nginx.sh
│   ├── 40-certificates.sh
│   └── 99-verify.sh
├── install.sh
├── bootstrap.sh
└── update-repo.sh
```
