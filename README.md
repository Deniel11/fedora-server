# Fedora Server Setup

Automated setup and configuration for a Fedora Server used as a small home-lab infrastructure server.

The project installs Fedora-side infrastructure, Docker applications, Nginx reverse proxying, HTTPS, Cockpit, and Proxmox access through a single HTTPS entry point.

## Domain and HTTPS modes

The installer now remembers the selected domain/TLS mode in:

```text
/etc/fedora-server-setup/domain.env
```

There are two modes.

### 1. Local mode (existing behaviour)

The default remains the existing `.home` layout:

```text
https://fedora-server.home
https://proxmox.home
https://portainer.home
https://vault.home
https://joplin.home
```

The server generates a private local CA and certificates. Client devices must trust that CA.

### 2. Public domain mode

The installer can use a real registered domain, for example:

```text
Base domain: danielczank.eu
Application subdomain: home
```

The resulting names are:

```text
https://fedora-server.home.danielczank.eu
https://proxmox.home.danielczank.eu
https://portainer.home.danielczank.eu
https://vault.home.danielczank.eu
https://joplin.home.danielczank.eu
```

Public mode obtains publicly trusted Let's Encrypt certificates automatically with ACME HTTP-01. No client-side CA installation is required.

The installer does **not** change DNS records or router settings, because those are environment-specific and the repository cannot safely guess them.

## Required DNS/router setup for public certificates

For public mode, the names used by the certificates must be publicly resolvable to the home's public IP while the certificate is being issued/renewed.

At the registrar/DNS provider, create records such as:

```text
home.danielczank.eu -> <home public IP>
```

and either individual records:

```text
fedora-server.home.danielczank.eu -> <home public IP>
proxmox.home.danielczank.eu       -> <home public IP>
portainer.home.danielczank.eu     -> <home public IP>
vault.home.danielczank.eu         -> <home public IP>
joplin.home.danielczank.eu        -> <home public IP>
```

or a wildcard record if your DNS setup supports it:

```text
*.home.danielczank.eu -> <home public IP>
```

On the router, forward:

```text
TCP 80  -> Fedora Server:80
TCP 443 -> Fedora Server:443
```

For normal LAN usage, the router/local DNS can override these names and resolve them directly to the Fedora Server's private IP. This keeps traffic inside the LAN while the certificates remain publicly trusted.

If port 80 cannot be reached from the Internet, the HTTP-01 method cannot issue/renew the certificates. In that situation DNS-01 is the appropriate alternative, but it requires automated DNS API access or a manually maintained DNS challenge. This repository deliberately does not store DNS credentials.

## Installation

Clone the repository:

```bash
git clone https://github.com/Deniel11/fedora-server.git
cd fedora-server
chmod +x install.sh bootstrap.sh update-repo.sh scripts/*.sh
sudo ./install.sh
```

On the first run the installer asks for the domain/TLS mode and saves the answer. Subsequent runs do not ask again.

To install everything:

```bash
sudo ./install.sh --all
```

To install/update one application:

```bash
sudo ./install.sh --app portainer
```

To list applications without changing the saved domain configuration:

```bash
sudo ./install.sh --list
```

## Changing the domain later

The installer supports changing the domain layout of an already configured server.

Run:

```bash
sudo ./install.sh --reconfigure-domain
```

You can switch between local `.home` mode and public-domain mode, or replace the registered domain/subdomain prefix.

When the domain configuration changes, the installer reconciles the managed server configuration:

* saved domain state is replaced
* old public ACME certificates are removed on a best-effort basis
* Nginx managed configuration is regenerated
* certificate paths are changed automatically
* old application proxy configuration is replaced
* Docker application data is preserved
* application containers are only recreated when the normal installer determines it is necessary, or when `--reconfigure` is used

For a full application reconciliation after a domain change:

```bash
sudo ./install.sh --all --reconfigure
```

Persistent application data under `/opt/fedora-server-apps` is not intentionally deleted by domain reconfiguration.

## Updating an existing server

Update the repository copy and then run:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
sudo /opt/fedora-server-setup/install.sh --all --reconfigure
```

The domain/TLS selection is read from `/etc/fedora-server-setup/domain.env`, so normal repository updates do not repeatedly ask the same questions.

## Domain state

Example public-domain state:

```bash
DOMAIN_MODE=public
BASE_DOMAIN=danielczank.eu
APP_SUBDOMAIN=home
ACME_EMAIL=admin@example.com
```

Example local state:

```bash
DOMAIN_MODE=local
BASE_DOMAIN=
APP_SUBDOMAIN=home
ACME_EMAIL=
```

The file is root-readable only:

```text
/etc/fedora-server-setup/domain.env
```

## DNS responsibility

The repository manages the Fedora Server side only. DNS remains outside the installer.

For local mode, the router/local DNS should point the `.home` names to the Fedora Server's private IP.

For public mode, the registered domain must have public DNS records suitable for ACME validation, and the router must forward TCP 80/443 to the Fedora Server.

The repository does not attempt to modify GoDaddy, another registrar, or a router because those interfaces and network topologies differ between installations.

## Included applications

* Cockpit
* Proxmox reverse proxy
* Portainer CE
* Vaultwarden
* Joplin Server

All managed application hostnames are derived automatically from the saved domain configuration.

For example, with:

```text
BASE_DOMAIN=danielczank.eu
APP_SUBDOMAIN=home
```

Portainer becomes:

```text
https://portainer.home.danielczank.eu
```

and Vaultwarden becomes:

```text
https://vault.home.danielczank.eu
```

## TLS certificate locations

Local mode:

```text
/etc/fedora-server-setup/tls/
```

Public mode:

```text
/etc/letsencrypt/live/<hostname>/
```

Public certificates are checked/renewed automatically by a systemd timer installed by the Nginx stage.

## Safety and persistence

The installer is intended to be idempotent.

* Application data is stored outside the repository.
* Domain configuration is stored outside the repository.
* Docker application data is not removed during domain changes.
* Managed Nginx files are regenerated from the repository.
* Certificates are renewed before expiry.
* Existing domain configuration is reused automatically on later runs.

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
