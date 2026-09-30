# Fedora Server Setup

Automated setup and configuration for a Fedora Server used as a small home-lab infrastructure server.

## HTTPS design

The public-domain mode uses **one publicly trusted Let's Encrypt wildcard certificate** for the application zone.

Example:

```text
Base domain: example.com
Application subdomain: home

Certificate:
  *.home.example.com
  home.example.com
```

The wildcard covers:

```text
https://fedora-server.home.example.com
https://proxmox.home.example.com
https://portainer.home.example.com
https://vault.home.example.com
https://joplin.home.example.com
```

The certificate also contains `home.example.com` as a separate SAN. This is intentional: a wildcard such as `*.home.example.com` does not cover `home.example.com` itself.

### Why this works without installing a local CA

The certificates are issued by Let's Encrypt, which is already trusted by normal operating systems and browsers.

Certificate issuance and renewal use the **ACME DNS-01 challenge**. The Fedora server therefore does **not** need to be reachable from the public Internet.

GoDaddy is used only as the authoritative DNS provider for the temporary `_acme-challenge` TXT record.

## DNS: what you need

You do **not** need to create every application hostname in GoDaddy.

### Public DNS

GoDaddy only needs to host the authoritative zone and allow the installer to create `_acme-challenge` TXT records through its API.

Do not expose the private Fedora Server address in public DNS unless you have a specific reason to do so.

### LAN DNS

Your router, Pi-hole, AdGuard Home, dnsmasq, or another local DNS server should resolve the service names to the correct private addresses.

For this installation, the Fedora Server is:

```text
192.168.1.20
```

Example LAN records:

```text
fedora-server.home.example.com -> 192.168.1.20
portainer.home.example.com     -> 192.168.1.20
vault.home.example.com         -> 192.168.1.20
joplin.home.example.com        -> 192.168.1.20
proxmox.home.example.com       -> <PROXMOX-IP>
```

The clients must use that LAN DNS server.

### Router/firewall

For a LAN-only installation:

- do **not** forward TCP 80 from the Internet to the Fedora Server;
- do **not** forward TCP 443 from the Internet to the Fedora Server;
- allow TCP 443 from your LAN to `192.168.1.20`;
- allow the required internal DNS traffic to your LAN DNS server.

Let's Encrypt does not need to connect to the Fedora Server during DNS-01 validation.

## GoDaddy API credentials

Public mode asks for a GoDaddy Personal Access Token.

The token is stored only on the server:

```text
/etc/fedora-server-setup/godaddy.ini
```

The file is root-owned and mode `600`.

Use the narrowest DNS permission available for the token. The setup expects permission to update DNS records for the zone.

The token is never stored in this repository.

## Certificate layout

Public mode uses one certificate lineage:

```text
/etc/letsencrypt/live/home.example.com/fullchain.pem
/etc/letsencrypt/live/home.example.com/privkey.pem
```

The exact path is derived from your configured application zone.

All managed Nginx virtual hosts use the same certificate and private key.

Renewal is handled by the systemd timer created by the Nginx stage. When Certbot successfully renews the wildcard certificate, Nginx is reloaded automatically.

## Automatic migration from the old certificate model

Earlier versions of this repository created one Let's Encrypt certificate per hostname.

The current certificate stage automatically cleans up those **managed** legacy lineages when it runs in public mode. It also removes the old repository-generated local CA/certificates when switching from local mode to public mode.

The cleanup is limited to certificate names owned by this repository. It does not remove Docker volumes, application data, or unrelated certificates.

If the domain configuration itself is changed with `--reconfigure-domain`, the previous domain state is also reconciled automatically.

## Installation

Clone the repository and run:

```bash
git clone https://github.com/Deniel11/fedora-server.git
cd fedora-server

chmod +x install.sh bootstrap.sh update-repo.sh scripts/*.sh

sudo ./install.sh
```

To install/update all applications:

```bash
sudo ./install.sh --all
```

To explicitly select public HTTPS during setup:

```bash
sudo ./install.sh --reconfigure-domain
```

Choose:

```text
2) Public domain + trusted ACME certificates
```

Then enter values similar to:

```text
Base domain: example.com
Application subdomain prefix: home
ACME contact email: admin@example.com
```

The actual domain used in your installation can be any domain you control; `example.com` is only documentation.

The installer will ask for the GoDaddy PAT if one is not already stored.

## Updating an existing installation

Update the repository files:

```bash
sudo /opt/fedora-server-setup/update-repo.sh
```

Then reconcile the managed configuration:

```bash
sudo /opt/fedora-server-setup/install.sh --all --reconfigure
```

For a domain/TLS change:

```bash
sudo /opt/fedora-server-setup/install.sh --reconfigure-domain
```

If you are migrating an existing installation from the old per-host certificate model, the normal `--all --reconfigure` run is sufficient after installing the updated repository.

## What the installer manages

The repository manages:

- Fedora packages required by the stack;
- Proxmox and Fedora network state;
- Docker and application containers;
- Nginx reverse-proxy configuration;
- local CA certificates in local mode;
- the Let's Encrypt wildcard certificate in public mode;
- the GoDaddy DNS-01 challenge hook;
- automatic certificate renewal;
- removal of stale managed Nginx configuration.

The repository does **not** manage:

- your router's port forwarding;
- your LAN DNS records;
- your GoDaddy domain registration;
- your GoDaddy DNS delegation;
- your application data outside the repository.

## Manual steps required outside the installer

For public HTTPS, complete these steps:

1. Own/control the public domain.
2. Make sure its authoritative DNS is GoDaddy DNS.
3. Create a GoDaddy PAT with DNS update permission.
4. Run the installer in public mode and enter the PAT.
5. Configure your LAN DNS so each service hostname resolves to its internal IP.
6. Point the Fedora service names to `192.168.1.20`.
7. Point the Proxmox hostname to the Proxmox private IP.
8. Make sure clients use the LAN DNS server.
9. Do not create Internet port forwards unless you intentionally want external access.
10. After installation, verify HTTPS from at least one browser/device.

## Verification

Check the installed state:

```bash
sudo /opt/fedora-server-setup/install.sh --list
```

Check Nginx:

```bash
sudo nginx -t
sudo systemctl status nginx
```

Check the certificate:

```bash
sudo /opt/fedora-server-setup/certbot-venv/bin/certbot certificates
```

Check the renewal timer:

```bash
systemctl status fedora-server-certbot-renew.timer
systemctl list-timers fedora-server-certbot-renew.timer
```

You can perform a renewal simulation with:

```bash
sudo /opt/fedora-server-setup/certbot-venv/bin/certbot renew --dry-run
```

The dry run still uses the configured DNS-01 hook, so GoDaddy API access must work.

## Security notes

- Keep the GoDaddy PAT private.
- Do not commit `/etc/fedora-server-setup/godaddy.ini`.
- Prefer a narrowly scoped DNS credential.
- Do not expose the Fedora Server publicly just to obtain a certificate.
- Keep TCP 443 LAN-only if these services are intended to remain private.
- The wildcard private key is shared by all managed Nginx virtual hosts. Protect `/etc/letsencrypt` accordingly.

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
