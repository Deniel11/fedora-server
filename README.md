# Fedora Server Home Services Setup

Automated, rerunnable setup for a Fedora Server VM on Proxmox.

The project intentionally keeps the runtime simple:

- Fedora Server for the host
- NetworkManager for the static IP
- Docker Engine + Docker Compose for applications
- Nginx as the HTTPS reverse proxy
- a small local Certificate Authority for internal `.home` names
- Cockpit remains a Fedora Server infrastructure component and is **not** managed as a Docker application
- every application lives in its own `apps/<name>/` module

The installer is designed to be safe to rerun. Existing healthy applications are not recreated just because the installer was started again.

## Architecture

```text
                         Fedora Server
                              |
              +---------------+---------------+
              |                               |
       Infrastructure                  Docker applications
              |                               |
       +------+------+              +---------+---------+
       |      |      |              |         |         |
   Network  Docker  Nginx       Portainer Vaultwarden Joplin
       |             |              |         |         |
       +------+------+--------------+---------+---------+
                              |
                         HTTPS / .home
                              |
                           OPNsense
                              |
                         WireGuard / DNS
```

The Fedora installer does not configure OPNsense, WireGuard or DNS. Those remain network-appliance responsibilities.

## What the installer configures

Mandatory infrastructure:

1. Fedora base packages and firewall preparation
2. Proxmox IP record
3. Fedora static IPv4 configuration through NetworkManager
4. Docker Engine + Docker Compose
5. local CA and application certificates
6. Nginx reverse proxy

Applications are optional and selected after the infrastructure options are displayed.

Current applications:

- Portainer CE
- Vaultwarden
- Joplin Server + PostgreSQL

Future applications can be added without modifying the main application-selection logic. Examples planned for the future include Jellyfin, Immich and a file-management application when additional storage is available.

## Central configuration

All visible domain and host-port assignments are kept in:

```text
config/domains.conf
```

Example:

```bash
PORTAINER_DOMAIN="portainer.home"
PORTAINER_PORT="9443"

VAULTWARDEN_DOMAIN="vault.home"
VAULTWARDEN_PORT="8080"
VAULTWARDEN_NOTIFICATIONS_HUB_PORT="3012"

JOPLIN_DOMAIN="joplin.home"
JOPLIN_PORT="22300"
```

The installer validates these values before changing the system.

It checks for:

- invalid hostnames
- invalid TCP ports
- duplicate domains
- duplicate host ports

If a conflict is found, installation stops before the affected services are deployed.

Container-internal ports are not part of this collision check. The check is for ports exposed on the Fedora host.

## First installation

Git is not required on the Fedora server.

### Bootstrap

From a fresh Fedora Server installation:

```bash
curl -fL https://raw.githubusercontent.com/Deniel11/fedora-server/main/bootstrap.sh \
  -o /tmp/bootstrap.sh

chmod +x /tmp/bootstrap.sh

sudo /tmp/bootstrap.sh
```

Bootstrap downloads the `main` branch, extracts it and installs the repository under:

```text
/opt/fedora-server-setup
```

Then start the installer:

```bash
sudo /opt/fedora-server-setup/install.sh
```

## Interactive installer

The default command is:

```bash
sudo ./install.sh
```

The installer first displays the available applications and their domains/ports.

It then asks:

```text
Do you want to install ALL listed applications? [y/N]:
```

If the answer is `yes`, every application is selected.

If the answer is `no`, the installer asks about each application individually.

After all answers are collected, it prints the final installation plan, waits four seconds, and starts the installation.

The infrastructure is always installed/configured first. Selected applications are installed afterwards.

## Quick commands

List applications:

```bash
sudo ./install.sh --list
```

Install every application:

```bash
sudo ./install.sh --all
```

Install only one application:

```bash
sudo ./install.sh --app portainer
sudo ./install.sh --app vaultwarden
sudo ./install.sh --app joplin
```

Show help:

```bash
sudo ./install.sh --help
```

The normal interactive installer remains the recommended first-install path because Proxmox and network settings may require operator input.

## Application module structure

Every Docker application follows the same layout:

```text
apps/<application>/
├── app.conf
├── compose.yml
├── install.sh
├── verify.sh
└── nginx.conf
```

### `app.conf`

Describes the application to the central installer:

```bash
APP_ID="joplin"
APP_NAME="Joplin Server"
APP_DOMAIN="${JOPLIN_DOMAIN}"
APP_PORT="${JOPLIN_PORT}"
APP_CONTAINER="joplin"
APP_TLS_NAME="joplin"
APP_NGINX_ENABLED="true"
APP_CERTIFICATE_ENABLED="true"
APP_HEALTHCHECK_URL="http://127.0.0.1:${JOPLIN_PORT}/"
```

### `compose.yml`

Contains the Docker Compose definition. Applications are started only through Docker Compose.

### `install.sh`

Implements the application installation lifecycle. It must be idempotent: if the application is already installed and healthy, rerunning the installer should not unnecessarily recreate it.

### `verify.sh`

Implements the application health check.

### `nginx.conf`

Defines the application reverse proxy. The central Nginx stage replaces these placeholders:

```text
__APP_DOMAIN__
__APP_PORT__
__APP_TLS_NAME__
```

## Application lifecycle

The installer standardizes the following concepts:

```text
is_installed
install
is_running
verify
```

The common helper functions live in:

```text
scripts/00-common.sh
```

Application-specific installation and health checks stay inside the application module.

The main installer discovers application modules automatically. Adding a new application therefore does not require editing `install.sh`, the certificate script or the Nginx script.

## Runtime data and secrets

Repository files and runtime data are intentionally separated.

Repository:

```text
/opt/fedora-server-setup
```

Application runtime data:

```text
/opt/fedora-server-apps
```

System state and secrets:

```text
/etc/fedora-server-setup
```

Do not commit:

- CA private keys
- TLS private keys
- database passwords
- `.env` files containing secrets
- databases
- application data
- access tokens

## Existing-install migration

The refactored Portainer deployment continues to use the existing Docker named volume:

```text
portainer_data
```

Vaultwarden data from the previous repository layout is copied from:

```text
/opt/fedora-server-setup/docker/vaultwarden/data
```

to:

```text
/opt/fedora-server-apps/vaultwarden/data
```

The old data is not deleted automatically.

Joplin PostgreSQL data is similarly migrated from:

```text
/opt/fedora-server-setup/docker/joplin/postgres-data
```

to:

```text
/opt/fedora-server-apps/joplin/postgres-data
```

The previous Joplin password file at:

```text
/etc/fedora-server-setup/joplin.env
```

is reused when available.

## Network changes and reconnect workflow

The Fedora static IP is configured through NetworkManager.

If the selected network configuration differs from the current one, the installer warns that the current SSH/Cockpit session may disconnect.

After applying the change, the installer waits approximately ten seconds and stops.

It tells the operator to reconnect and run:

```bash
sudo /opt/fedora-server-setup/install.sh
```

The network stage is then detected as already completed and the installation continues.

This is deliberate: the installer does not try to continue blindly across a network/session change.

## System updates and reboot workflow

At the beginning of a normal installation, the installer checks for pending Fedora updates.

If updates are available, it offers to install them and then stops.

If a reboot is required, the installer tells the operator to reboot and rerun:

```bash
sudo /opt/fedora-server-setup/install.sh
```

The installer does not automatically reboot the machine because the normal use case may be a remote SSH session.

## Cockpit

Cockpit is treated as Fedora Server infrastructure, not as a Docker application.

The application discovery system does not include Cockpit.

The installer does not require a `apps/cockpit/` module and does not expose Cockpit in the application-selection menu.

Cockpit normally comes with Fedora Server. The final verification stage reports its socket state but does not treat an inactive Cockpit socket as a Docker application failure.

## TLS / certificates

The project creates a local Certificate Authority because `.home` is an internal domain.

Generated TLS files are stored in:

```text
/etc/fedora-server-setup/tls/
```

The CA private key is root-readable only.

Application certificates contain both:

- the configured DNS name
- the current Fedora static IP as an IP SAN

If the Fedora IP changes, rerunning the installer causes certificates to be regenerated when their SAN no longer matches.

Trust the CA on client devices by importing:

```text
/etc/fedora-server-setup/tls/ca.crt
```

Without trusting the CA, browsers will correctly display a certificate trust warning.

## Nginx

Nginx is the HTTPS entry point for Docker applications.

Applications bind their Docker ports to `127.0.0.1` on the Fedora host. Clients therefore reach applications through Nginx rather than directly through Docker-published ports.

Nginx configurations are generated automatically from the application modules.

The main Nginx stage does not contain application-specific blocks for Portainer, Vaultwarden or Joplin.

## OPNsense, DNS and WireGuard

The Fedora repository deliberately does not configure OPNsense.

The expected future setup is:

```text
Internet
   |
OPNsense
   |
   +-- DNS
   +-- Firewall
   +-- WireGuard
          |
       Home LAN
          |
   Fedora Server
```

The DNS records should point the application domains to the Fedora static IP.

Example:

```text
fedora-server.home -> FEDORA_STATIC_IP
portainer.home     -> FEDORA_STATIC_IP
vault.home         -> FEDORA_STATIC_IP
joplin.home        -> FEDORA_STATIC_IP
proxmox.home       -> PROXMOX_IP
```

## Updating the repository

The repository can be updated without Git:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
```

The update script downloads the latest `main` branch from GitHub and replaces repository files.

Runtime application data is stored outside the repository under `/opt/fedora-server-apps`, so updating the repository does not replace application databases or uploads.

After an update, rerun:

```bash
sudo /opt/fedora-server-setup/install.sh
```

The installer is idempotent and applies new configuration only where required.

## Container updates

The normal installer does **not** pull every latest image on every run.

This is intentional.

For a deliberate application update, use its Compose directory in the runtime tree:

```bash
cd /opt/fedora-server-apps/portainer
sudo docker compose pull
sudo docker compose up -d
```

For Vaultwarden:

```bash
cd /opt/fedora-server-apps/vaultwarden
sudo docker compose pull
sudo docker compose up -d
```

For Joplin:

```bash
cd /opt/fedora-server-apps/joplin
sudo docker compose pull
sudo docker compose up -d
```

Read the application's release notes before major upgrades, especially for database-backed applications.

## Backups

At minimum, back up:

```text
/etc/fedora-server-setup/
/opt/fedora-server-apps/
```

For the current applications this includes Portainer's Docker volume and the Vaultwarden/Joplin data directories.

## Troubleshooting

Check Docker:

```bash
sudo systemctl status docker
sudo docker ps
```

Check Nginx:

```bash
sudo nginx -t
sudo systemctl status nginx
sudo journalctl -u nginx -e
```

Check a specific application:

```bash
sudo docker compose -f /opt/fedora-server-apps/portainer/compose.yml ps
sudo docker compose -f /opt/fedora-server-apps/vaultwarden/compose.yml ps
sudo docker compose -f /opt/fedora-server-apps/joplin/compose.yml ps
```

Run the complete verification stage again:

```bash
sudo /opt/fedora-server-setup/scripts/99-verify.sh
```

## ShellCheck

The scripts are intended to be ShellCheck-friendly:

```bash
shellcheck install.sh scripts/*.sh apps/*/*.sh
```

## License

MIT. See `LICENSE`.
