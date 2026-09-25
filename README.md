# Fedora Server Setup

Automated setup and configuration for a Fedora Server used as a small home-lab infrastructure server.

The project installs and configures the server itself, Docker-based applications, Nginx reverse proxying, HTTPS certificates, Cockpit, and Proxmox access through a single HTTPS entry point.

The goal is to make a fresh Fedora Server easy to configure while also allowing an existing installation to be updated and reconfigured safely.

---

## What is this?

`fedora-server` is a shell-based server setup and configuration project.

It is designed for a Fedora Server that acts as the central entry point for services in a home lab.

Instead of accessing every service directly by IP address and port, services can be accessed through local HTTPS hostnames such as:

```text
https://fedora-server.home
https://proxmox.home
https://portainer.home
https://vault.home
https://joplin.home
```

The Fedora server runs Nginx as the central reverse proxy.

Example architecture:

```text
                         Home Network
                              |
                              |
                       Router / DNS
                              |
              *.home -> Fedora Server
                              |
                    192.168.1.20:443
                              |
                         Fedora Nginx
                              |
        +---------------------+----------------------+
        |                     |                      |
        v                     v                      v
    Cockpit               Proxmox                Docker apps
  127.0.0.1:9090       PROXMOX_IP:8006
```

The router only needs to point the local service names to the Fedora Server.

The actual Proxmox IP remains the backend address and is configured on the Fedora Server.

---

# Features

The project provides:

* Fedora Server system preparation
* Cockpit installation and configuration
* Nginx reverse proxy
* HTTPS for all managed services
* A local Certificate Authority
* Automatically generated TLS certificates
* Separate TLS certificates for Fedora Server and Proxmox
* Proxmox reverse proxy support
* Docker and Docker Compose setup
* Application deployment
* Persistent application data
* Application-specific Nginx configuration
* Interactive Proxmox backend IP configuration
* Configuration validation
* Installation verification
* Safe reconfiguration of an existing installation
* Repository update support

---

# Included Applications

The repository currently supports the following services.

## Cockpit

Cockpit provides a web-based administration interface for the Fedora Server.

It is available through:

```text
https://fedora-server.home
```

Cockpit itself normally listens on:

```text
https://127.0.0.1:9090
```

Nginx handles the external HTTPS connection and forwards traffic to Cockpit.

---

## Proxmox

The Proxmox web interface is published through the Fedora Server.

Users access:

```text
https://proxmox.home
```

Nginx forwards the connection to:

```text
https://<PROXMOX_IP>:8006
```

The Proxmox IP address is requested interactively during installation and stored locally in:

```text
/etc/fedora-server-setup/proxmox.env
```

Example:

```bash
PROXMOX_IP=192.168.1.10
```

The Proxmox IP is not hard-coded into the Nginx configuration files.

The Proxmox host itself keeps its own network configuration and HTTPS service.

---

## Portainer

Portainer provides a web interface for managing Docker containers.

It is available through:

```text
https://portainer.home
```

The Portainer container uses persistent storage so that configuration and Docker management data survive container recreation.

---

## Vaultwarden

Vaultwarden is a Bitwarden-compatible password manager server.

It is available through:

```text
https://vault.home
```

Vaultwarden data is stored persistently and is not removed when the container is recreated.

---

## Joplin

Joplin Server provides a self-hosted synchronization service for Joplin clients.

It is available through:

```text
https://joplin.home
```

Its database and application data are stored persistently.

---

# Requirements

Before running the installer, you need:

* A Fedora Server installation
* Root or `sudo` access
* Internet access
* A working local network
* Docker-compatible hardware if Docker applications are enabled
* A router or local DNS server that supports custom DNS records

The system is intended for a private/home network.

---

# DNS Configuration

The local DNS server should point the service names to the Fedora Server.

For example, if the Fedora Server has IP:

```text
192.168.1.20
```

DNS should contain:

```text
fedora-server.home -> 192.168.1.20
proxmox.home       -> 192.168.1.20
portainer.home     -> 192.168.1.20
vault.home         -> 192.168.1.20
joplin.home        -> 192.168.1.20
```

This is intentional.

Do **not** point:

```text
proxmox.home
```

directly to the Proxmox IP.

Instead:

```text
Client
   |
   v
proxmox.home
   |
   v
Fedora Server / Nginx
   |
   v
Proxmox IP:8006
```

This allows the Fedora Server to manage HTTPS termination and reverse proxying for all services.

---

# HTTPS and Certificates

The project creates its own local Certificate Authority.

Certificates are generated for the local `.home` domains.

The main certificates include:

```text
fedora-server.crt
fedora-server.key

proxmox.crt
proxmox.key
```

The Proxmox certificate contains both:

```text
DNS:proxmox.home
IP:<PROXMOX_IP>
```

The Fedora Server certificate contains the Fedora hostname and server IP.

Because the certificates are issued by a local CA, client devices must trust that CA to avoid browser certificate warnings.

The CA files are stored under:

```text
/etc/fedora-server-setup/tls/
```

Existing valid certificates are preserved and are only regenerated when necessary.

---

# Repository Structure

The main structure is:

```text
fedora-server/
├── apps/
│   ├── portainer/
│   ├── vaultwarden/
│   └── joplin/
│
├── config/
│   ├── domains.conf
│   ├── cockpit.conf
│   ├── fedora-server.nginx.conf
│   └── proxmox.nginx.conf
│
├── scripts/
│   ├── 00-common.sh
│   ├── 01-system.sh
│   ├── 02-proxmox.sh
│   ├── 03-network.sh
│   ├── 04-docker.sh
│   ├── 05-nginx.sh
│   ├── 40-certificates.sh
│   └── 99-verify.sh
│
├── install.sh
├── bootstrap.sh
├── update-repo.sh
└── README.md
```

---

# Installation

Clone the repository:

```bash
git clone https://github.com/Deniel11/fedora-server.git
```

Enter the repository:

```bash
cd fedora-server
```

Make the scripts executable if necessary:

```bash
chmod +x install.sh bootstrap.sh update-repo.sh
chmod +x scripts/*.sh
```

Run the installer:

```bash
sudo ./install.sh
```

The installer will guide you through the available configuration.

---

# Installing Everything

To install all supported components:

```bash
sudo ./install.sh --all
```

This installs and configures the main infrastructure and applications.

The installer is designed to be idempotent.

Running it again normally does not unnecessarily recreate containers or destroy existing data.

---

# Reconfiguring an Existing Server

The project also supports servers that have already been installed.

This is important when the repository configuration changes after the initial installation.

First update the local repository:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
```

Then run:

```bash
sudo /opt/fedora-server-setup/install.sh --all --reconfigure
```

The `--reconfigure` option tells the installer to apply the current repository configuration to the existing server.

This can:

* rewrite managed configuration files
* update Nginx configuration
* update Cockpit configuration
* update certificates when required
* update application configuration
* recreate Docker containers when required
* apply the current repository configuration to existing services

Persistent application data is not intentionally deleted.

---

# Normal Installation vs. Reconfiguration

Normal installation:

```bash
sudo ./install.sh --all
```

This is intended to be safe to run repeatedly.

Existing, correctly configured services are generally left running.

Reconfiguration:

```bash
sudo ./install.sh --all --reconfigure
```

This explicitly tells the installer to reconcile the existing server with the current repository configuration.

Use this after changing configuration files in the repository.

For example:

```text
Repository changed
       |
       v
Update repository
       |
       v
Run --reconfigure
       |
       v
Existing server receives new configuration
```

---

# Updating the Server

The repository contains an update helper:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
```

After updating the repository, apply the changes with:

```bash
sudo /opt/fedora-server-setup/install.sh --all --reconfigure
```

This is the recommended workflow when the server already exists.

---

# Proxmox Configuration

During installation, the Proxmox stage asks for the backend IP address.

Example:

```text
Proxmox IPv4 address [192.168.1.10]:
```

Enter the real IP address of the Proxmox server.

For example:

```text
192.168.1.10
```

The value is stored in:

```text
/etc/fedora-server-setup/proxmox.env
```

Example:

```bash
PROXMOX_IP=192.168.1.10
```

If the installer is run again, the existing value is detected.

You can choose to keep it or change it.

The IP address stored here is the **backend address** used by Fedora Nginx.

It does not modify the Proxmox host's own network configuration.

---

# Accessing Services

After installation and DNS configuration, services can be accessed using:

| Service                 | URL                          |
| ----------------------- | ---------------------------- |
| Fedora Server / Cockpit | `https://fedora-server.home` |
| Proxmox                 | `https://proxmox.home`       |
| Portainer               | `https://portainer.home`     |
| Vaultwarden             | `https://vault.home`         |
| Joplin                  | `https://joplin.home`        |

The Fedora Server is the HTTPS entry point.

---

# Nginx Reverse Proxy

Nginx listens on:

```text
HTTP  :80
HTTPS :443
```

HTTP requests are redirected to HTTPS.

For example:

```text
http://proxmox.home
```

is redirected to:

```text
https://proxmox.home
```

Nginx then forwards the request to the appropriate backend.

For Proxmox:

```text
https://proxmox.home
        |
        v
Fedora Nginx
        |
        v
https://<PROXMOX_IP>:8006
```

For Cockpit:

```text
https://fedora-server.home
        |
        v
Fedora Nginx
        |
        v
https://127.0.0.1:9090
```

WebSocket support is configured for services that require it.

---

# Persistent Data

Docker containers may be recreated during reconfiguration.

Persistent application data is stored outside the disposable container itself.

Therefore:

```text
container recreation != data deletion
```

The reconfiguration process does not intentionally remove application volumes or persistent data.

However, backups are still strongly recommended before major server changes.

---

# Configuration Files

Global domains and ports are defined in:

```text
config/domains.conf
```

Example:

```bash
PROXMOX_DOMAIN="proxmox.home"
FEDORA_DOMAIN="fedora-server.home"
PROXMOX_PORT="8006"
FEDORA_PORT="9090"
```

Application domains and ports are also defined there.

Nginx templates are stored in:

```text
config/
```

The installer replaces template variables with the actual configured values.

---

# Verification

After installation, run:

```bash
sudo ./scripts/99-verify.sh
```

The verification stage checks the important parts of the installation, including:

* required services
* Nginx configuration
* HTTPS configuration
* generated certificates
* Proxmox configuration
* Docker applications
* reverse proxy configuration

If something is not working, run the verification script before changing the configuration manually.

---

# Useful Commands

Check Nginx configuration:

```bash
sudo nginx -t
```

Check Nginx status:

```bash
sudo systemctl status nginx
```

Restart Nginx:

```bash
sudo systemctl restart nginx
```

Reload Nginx after a configuration change:

```bash
sudo systemctl reload nginx
```

Check Cockpit:

```bash
sudo systemctl status cockpit.socket
```

Check Docker:

```bash
sudo systemctl status docker
```

Check running containers:

```bash
sudo docker ps
```

Check stored Proxmox configuration:

```bash
sudo cat /etc/fedora-server-setup/proxmox.env
```

---

# Troubleshooting

## `proxmox.home` does not open

First verify DNS:

```bash
getent hosts proxmox.home
```

It should resolve to the Fedora Server IP.

For example:

```text
192.168.1.20 proxmox.home
```

It should **not** resolve directly to the Proxmox IP.

Then test Nginx:

```bash
sudo nginx -t
```

Check the stored backend IP:

```bash
sudo cat /etc/fedora-server-setup/proxmox.env
```

Then verify that Fedora can reach Proxmox:

```bash
curl -k https://<PROXMOX_IP>:8006
```

---

## Cockpit reports an invalid origin

Check:

```bash
sudo cat /etc/cockpit/cockpit.conf
```

The configuration should contain the Fedora hostname as an allowed origin and should use:

```ini
ProtocolHeader = X-Forwarded-Proto
```

Then reload Cockpit/Nginx as appropriate.

---

## Browser reports a certificate warning

This usually means the client does not trust the project's local Certificate Authority.

Install and trust the generated CA certificate on the client device.

Do not replace the local CA with an unrelated certificate unless you intentionally want to change the certificate architecture.

---

## Application configuration has changed but the old container is still running

Update the repository:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
```

Then run:

```bash
sudo /opt/fedora-server-setup/install.sh --all --reconfigure
```

The reconfiguration mode is specifically intended for this situation.

---

# Design Principles

The project follows several principles:

### Idempotent installation

Running the installer repeatedly should not unnecessarily destroy or recreate working services.

### Explicit reconfiguration

Changes to an existing server are applied explicitly with:

```bash
--reconfigure
```

### Persistent data protection

Application data is kept separate from disposable containers.

### Centralized HTTPS

Nginx provides the central HTTPS entry point.

### No hard-coded Proxmox backend

The Proxmox IP is stored in:

```text
/etc/fedora-server-setup/proxmox.env
```

rather than being duplicated throughout the repository.

### Repository as the source of configuration

The repository contains the desired server configuration.

The installer applies that configuration to the server.

---

# Recommended Workflow

For a new Fedora Server:

```bash
git clone https://github.com/Deniel11/fedora-server.git
cd fedora-server
sudo ./install.sh --all
```

For an existing server:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
sudo /opt/fedora-server-setup/install.sh --all --reconfigure
```

Then verify:

```bash
sudo ./scripts/99-verify.sh
```

Finally test the services from a client:

```text
https://fedora-server.home
https://proxmox.home
https://portainer.home
https://vault.home
https://joplin.home
```

---

# Security Notes

This project is primarily intended for a trusted local/home network.

The `.home` domains and local Certificate Authority are designed for internal use.

Do not expose the management interfaces directly to the public Internet without implementing an appropriate security architecture.

In particular, avoid exposing:

```text
Cockpit
Proxmox
Portainer
Vaultwarden
```

directly to the Internet unless you have deliberately configured the required authentication, firewalling, TLS, access control, and monitoring.

Regular backups of persistent application data are recommended.

---

# Repository

GitHub:

https://github.com/Deniel11/fedora-server

The repository should be treated as the source of truth for the desired server configuration.

When the repository changes, update the server and run the installer in reconfiguration mode:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
sudo /opt/fedora-server-setup/install.sh --all --reconfigure
```

---

# Summary

`fedora-server` turns a Fedora Server into a centrally managed home-lab server.

It provides:

* Fedora Server administration through Cockpit
* Proxmox access through Nginx
* Docker application management
* Local HTTPS
* Local Certificate Authority
* Centralized DNS-based service names
* Persistent application data
* Repeatable installation
* Existing-server reconfiguration
* Repository-based configuration management

The basic model is:

```text
                    Local DNS
                       |
                       v
              Fedora Server :443
                       |
                    Nginx
                       |
       +---------------+----------------+
       |               |                |
       v               v                v
    Cockpit         Proxmox         Docker Apps
   :9090             :8006          Portainer
                                    Vaultwarden
                                    Joplin
```

The repository is designed to make this setup reproducible, maintainable, and easy to update without manually editing every server configuration file.