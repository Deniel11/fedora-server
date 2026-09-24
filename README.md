# Fedora Server Setup

Automated setup and configuration for a Fedora Server home lab.

The repository configures a Fedora Server with:

* Static network configuration
* Local Certificate Authority
* HTTPS certificates for internal services
* Nginx reverse proxy
* Cockpit over HTTPS
* Proxmox reverse proxy over HTTPS
* Docker and Docker Compose
* Optional application services
* Firewall and SELinux configuration
* Verification of the resulting setup

## Architecture

The Fedora Server acts as the central HTTPS reverse proxy for both local services and external infrastructure.

```text
                         Home LAN
                            │
                            │
                    ┌───────▼────────┐
                    │  Fedora Server │
                    │                │
                    │ Nginx :80/443 │
                    └───────┬────────┘
                            │
             ┌──────────────┼──────────────┐
             │              │              │
             │              │              │
      ┌──────▼──────┐ ┌─────▼─────┐ ┌─────▼────────┐
      │   Cockpit   │ │  Docker   │ │   Proxmox    │
      │ 127.0.0.1   │ │ containers │ │ <PROXMOX_IP> │
      │    :9090    │ │            │ │    :8006     │
      └─────────────┘ └────────────┘ └──────────────┘
```

### HTTPS endpoints

| Hostname                     | Backend                     | Purpose              |
| ---------------------------- | --------------------------- | -------------------- |
| `https://fedora-server.home` | `https://127.0.0.1:9090`    | Fedora Cockpit       |
| `https://proxmox.home`       | `https://<PROXMOX_IP>:8006` | Proxmox Web UI       |
| Application hostnames        | Docker application ports    | Application services |

The Fedora Server terminates HTTPS using certificates issued by the repository's local Certificate Authority.

For Proxmox, the backend connection remains HTTPS on port `8006`. Nginx does not validate the Proxmox backend certificate because the public-facing certificate is managed by the Fedora Server's local CA.

## Repository Structure

```text
.
├── config/
│   ├── apps/
│   ├── cockpit.conf
│   ├── domains.conf
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
│   ├── ...
│   └── 99-verify.sh
├── install.sh
└── README.md
```

## Requirements

* Fedora Server
* Root privileges
* A working network connection
* A DNS resolver or local DNS configuration capable of resolving the configured `.home` hostnames
* A Proxmox host reachable from the Fedora Server
* Git, if the repository is being cloned or updated manually

The setup scripts are intended to be run as `root` or through `sudo`.

## Installation

Clone the repository:

```bash
git clone https://github.com/Deniel11/fedora-server.git
cd fedora-server
```

Run the installer:

```bash
sudo ./install.sh
```

The installer runs the setup stages in order:

```text
01-system.sh
02-proxmox.sh
03-network.sh
04-docker.sh
40-certificates.sh
05-nginx.sh
...
99-verify.sh
```

## Proxmox Configuration

The Proxmox IP address is requested interactively by `02-proxmox.sh`.

Example:

```text
Enter Proxmox IP [192.168.1.10]:
```

The selected address is stored locally in:

```text
/etc/fedora-server-setup/proxmox.env
```

Example:

```bash
PROXMOX_IP=192.168.1.10
```

The IP is therefore defined in one place rather than being duplicated in the Nginx or certificate configuration.

The stored value is subsequently used by:

* the Proxmox TLS certificate generation
* the Proxmox Nginx reverse proxy configuration
* the verification stage

The Proxmox host continues to provide its own HTTPS service on port `8006`.

## Domain Configuration

Infrastructure domains and ports are defined in:

```text
config/domains.conf
```

Current infrastructure configuration:

```bash
PROXMOX_DOMAIN="proxmox.home"
FEDORA_DOMAIN="fedora-server.home"

PROXMOX_PORT="8006"
FEDORA_PORT="9090"
```

Application domains and ports are configured in the same file and application-specific configuration files.

Do not place the Proxmox IP address in `domains.conf`.

The IP is intentionally collected by `02-proxmox.sh` and stored in:

```text
/etc/fedora-server-setup/proxmox.env
```

## Cockpit

Cockpit is installed as part of the base system.

The installer enables the Cockpit package and configures its reverse-proxy settings in:

```text
/etc/cockpit/cockpit.conf
```

The relevant configuration is:

```ini
[WebService]
Origins = https://fedora-server.home
ProtocolHeader = X-Forwarded-Proto
```

Cockpit itself continues listening locally on:

```text
https://127.0.0.1:9090
```

It is not exposed directly as the public HTTPS endpoint.

Nginx provides the public endpoint:

```text
https://fedora-server.home
```

The Fedora Server certificate is:

```text
/etc/fedora-server-setup/tls/fedora-server.crt
```

and its private key is:

```text
/etc/fedora-server-setup/tls/fedora-server.key
```

## Proxmox Reverse Proxy

Nginx publishes the Proxmox Web UI at:

```text
https://proxmox.home
```

The backend is:

```text
https://<PROXMOX_IP>:8006
```

The runtime Nginx configuration is generated at:

```text
/etc/nginx/conf.d/proxmox.conf
```

The configuration uses:

```nginx
proxy_pass https://<PROXMOX_IP>:8006;
proxy_ssl_verify off;
```

`proxy_ssl_verify off` is intentional because the Proxmox host normally uses its own certificate, which is independent from the Fedora Server local CA.

The client-facing certificate is instead generated by the Fedora Server setup:

```text
/etc/fedora-server-setup/tls/proxmox.crt
/etc/fedora-server-setup/tls/proxmox.key
```

The Proxmox certificate contains:

```text
DNS:proxmox.home
IP Address:<PROXMOX_IP>
```

The Nginx configuration also forwards WebSocket-related headers required by the Proxmox Web UI.

## Local Certificate Authority

The setup creates a local Certificate Authority under:

```text
/etc/fedora-server-setup/tls/
```

The CA files are:

```text
ca.key
ca.crt
```

The CA certificate is valid for the home lab and is used to sign certificates for internal HTTPS services.

Generated certificates include:

```text
fedora-server.crt
proxmox.crt
```

and certificates for enabled applications.

The CA private key must remain protected.

The setup uses:

```text
/etc/fedora-server-setup/tls/ca.key
```

with restrictive permissions.

## Trusting the Local CA

Client machines must trust:

```text
/etc/fedora-server-setup/tls/ca.crt
```

before browsers will consider the internal HTTPS certificates trusted.

The exact installation procedure depends on the client operating system.

After installing the CA certificate, clients should be able to access:

```text
https://fedora-server.home
https://proxmox.home
```

without browser certificate warnings, provided the corresponding `.home` names resolve correctly.

## DNS

The configured hostnames must resolve to the Fedora Server's IP address for the reverse-proxied services.

For example:

```text
fedora-server.home -> <FEDORA_SERVER_IP>
proxmox.home       -> <FEDORA_SERVER_IP>
```

Notice that `proxmox.home` points to the **Fedora Server**, not directly to the Proxmox host.

The traffic flow is:

```text
Client
  │
  │ https://proxmox.home
  ▼
Fedora Server
  │
  │ Nginx HTTPS reverse proxy
  ▼
Proxmox <PROXMOX_IP>:8006
```

## Firewall

The setup enables the following firewall services:

```text
http
https
cockpit
```

The public HTTPS entry point is therefore:

```text
TCP/443
```

The Proxmox port `8006` does not need to be exposed to clients through the Fedora Server.

The Fedora Server only needs network access to the Proxmox host on TCP port `8006`.

## SELinux

Nginx operates as a reverse proxy and therefore needs permission to make outbound network connections.

The setup enables:

```text
httpd_can_network_connect
```

when the SELinux tooling is available.

This is required for Nginx to proxy traffic to:

```text
127.0.0.1:9090
```

and:

```text
<PROXMOX_IP>:8006
```

## Nginx Configuration

The repository contains separate configuration templates for the infrastructure endpoints.

### Fedora / Cockpit

```text
config/fedora-server.nginx.conf
```

Installed as:

```text
/etc/nginx/conf.d/fedora-server.conf
```

### Proxmox

```text
config/proxmox.nginx.conf
```

Installed as:

```text
/etc/nginx/conf.d/proxmox.conf
```

Both configurations redirect HTTP to HTTPS.

Nginx uses the local CA certificates generated by the certificate stage.

## Application Reverse Proxies

Docker applications continue to use the repository's existing application configuration mechanism.

Application definitions are stored under:

```text
config/apps/
```

The common Nginx installation logic in:

```text
scripts/00-common.sh
```

generates the runtime application configurations from their templates.

The infrastructure reverse proxies for Cockpit and Proxmox are configured separately because neither service is a Docker application.

## Persistent State

The setup stores runtime state under:

```text
/etc/fedora-server-setup/
```

Important state files include:

```text
/etc/fedora-server-setup/network.env
/etc/fedora-server-setup/proxmox.env
/etc/fedora-server-setup/selected-apps.env
```

TLS material is stored under:

```text
/etc/fedora-server-setup/tls/
```

This separation keeps installation state and generated secrets outside the Git repository.

## Updating the Installation

The repository can be updated normally:

```bash
cd /path/to/fedora-server
git pull
```

Configuration templates can then be reapplied by running the relevant setup stages.

For example:

```bash
sudo ./scripts/40-certificates.sh
sudo ./scripts/05-nginx.sh
```

The full installer can also be run again:

```bash
sudo ./install.sh
```

The Proxmox IP is reused from:

```text
/etc/fedora-server-setup/proxmox.env
```

so it does not need to be entered again unless the state file is removed or the configuration is intentionally changed.

## Verification

The final verification stage is:

```bash
sudo ./scripts/99-verify.sh
```

Useful manual checks include:

### Nginx configuration

```bash
sudo nginx -t
```

### Services

```bash
sudo systemctl status nginx
sudo systemctl status cockpit.socket
```

### Cockpit configuration

```bash
sudo cat /etc/cockpit/cockpit.conf
```

### Generated Nginx configuration

```bash
sudo cat /etc/nginx/conf.d/fedora-server.conf
sudo cat /etc/nginx/conf.d/proxmox.conf
```

### Proxmox state

```bash
sudo cat /etc/fedora-server-setup/proxmox.env
```

### HTTPS endpoints

```bash
curl -kI https://fedora-server.home
curl -kI https://proxmox.home
```

### Fedora Server certificate

```bash
sudo openssl x509 \
    -in /etc/fedora-server-setup/tls/fedora-server.crt \
    -noout -subject -issuer -ext subjectAltName
```

### Proxmox certificate

```bash
sudo openssl x509 \
    -in /etc/fedora-server-setup/tls/proxmox.crt \
    -noout -subject -issuer -ext subjectAltName
```

The Proxmox certificate should contain:

```text
DNS:proxmox.home
IP Address:<PROXMOX_IP>
```

## Git Workflow

The repository is intentionally kept separate from generated runtime state.

Do not commit:

```text
/etc/fedora-server-setup/
```

or generated private keys.

Before committing repository changes:

```bash
git diff --check
git diff
```

Shell scripts can be syntax-checked with:

```bash
bash -n scripts/01-system.sh
bash -n scripts/05-nginx.sh
bash -n scripts/40-certificates.sh
```

After verifying the changes:

```bash
git add README.md \
    config/cockpit.conf \
    config/fedora-server.nginx.conf \
    config/proxmox.nginx.conf \
    scripts/01-system.sh \
    scripts/05-nginx.sh \
    scripts/40-certificates.sh

git commit -m "feat: proxy Cockpit and Proxmox through Nginx"
git push
```

## Commit

Recommended commit message:

```text
feat: proxy Cockpit and Proxmox through Nginx
```

This change introduces:

* Cockpit installation and reverse-proxy configuration
* Fedora Server HTTPS endpoint
* Proxmox HTTPS reverse proxy
* Proxmox-specific local CA certificate
* Proxmox IP reuse from `proxmox.env`
* Nginx WebSocket forwarding for Proxmox
* SELinux configuration for reverse-proxy connections
* Updated documentation