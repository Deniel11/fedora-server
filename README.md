# Fedora Server Setup

This repository automates a Fedora Server home-lab stack.

## State-aware installer

Run:

```bash
sudo ./install.sh
```

The installer first detects previously installed applications and saved settings.

If neither is found it explicitly reports that no applications and no saved settings were found, then performs a complete first-time configuration.

If existing state is found it loads the saved settings and presents:

```text
1) Update the existing installation
2) Modify saved settings and application selection
3) Remove one application
4) Remove the complete managed server package
5) Exit without changes
```

Each configuration question is a single normal prompt, and the text immediately before it explains what the question controls.

## Application selection

A fresh installation asks one question per available application, for example:

```text
Install/update Joplin Server (joplin.home.example.com, host port 22300)? [y/N]:
```

The selection is saved in:

```text
/etc/fedora-server-setup/selected-apps.env
```

## Update and settings changes

For a normal update, choose `1` from the interactive menu. Saved domain, network, Proxmox and application selection state is reused.

Choose `2` to change HTTPS/domain settings and application selection.

Convenience modes remain available:

```bash
sudo ./install.sh --all
sudo ./install.sh --app joplin
sudo ./install.sh --reconfigure
sudo ./install.sh --reconfigure-domain
sudo ./install.sh --list
```

## Removing applications

Choose `3` from the interactive menu. The installer asks whether persistent Docker volumes should also be deleted. Volumes are preserved unless deletion is explicitly confirmed.

## Removing the managed server package

Choose `4` to remove repository-managed containers, Nginx configuration, renewal timer, managed TLS material, installer state and the Certbot environment.

The removal does not remove Fedora, Docker packages, unrelated Docker data, router/LAN DNS settings, or the Git repository. Application volumes are only deleted when explicitly confirmed.

## HTTPS

Public mode uses one Let's Encrypt certificate containing:

```text
home.example.com
*.home.example.com
```

The exact names are derived from the configured base domain and application prefix.

The wildcard covers application hosts such as:

```text
fedora-server.home.example.com
proxmox.home.example.com
portainer.home.example.com
vault.home.example.com
joplin.home.example.com
```

DNS-01 validation is used, so the Fedora Server does not need inbound Internet TCP 80/443 access.

For LAN-only access, configure your local DNS so the service names resolve to the private server addresses and do not create Internet port forwards.

## GoDaddy API

The DNS hook uses the current GoDaddy Domains v3 DNS API:

```text
https://api.godaddy.com/v3/domains/zones/<zone>/dns-records
```

The PAT needs:

```text
domains.domain:read
domains.dns:update
```

The PAT is stored only on the server at:

```text
/etc/fedora-server-setup/godaddy.ini
```

with root-only permissions.

The hook performs a preflight API request before creating the ACME TXT record. Errors are classified:

- `401`: the PAT is invalid, expired, revoked or malformed;
- `403`: the PAT is valid but lacks required permissions;
- `404`: the domain/zone is not available through the authenticated GoDaddy account or is not hosted on GoDaddy authoritative DNS.

### Testing GoDaddy access

Replace the example domain with your actual zone:

```bash
sudo bash -c '
source /etc/fedora-server-setup/godaddy.ini
curl -fsS \
  -H "Authorization: Bearer ${GODADDY_PAT}" \
  -H "Accept: application/json" \
  "https://api.godaddy.com/v3/domains/zones/example.com/dns-records?type=TXT&name=_acme-challenge&page=1&pageSize=1"
'
```

A `401` requires a new PAT. A `403` requires correcting the PAT scopes.

## Migration from older TLS configuration

Older versions created one Let's Encrypt certificate per hostname. The certificate stage now removes the repository-managed legacy host lineages and uses one application-zone wildcard certificate.

Changing the saved domain configuration also reconciles the previous certificate state.

Certificate migration never deletes Docker volumes or application data.

## Manual steps outside the installer

You must still:

1. control the public domain;
2. keep authoritative DNS on GoDaddy when using this hook;
3. create the GoDaddy PAT with the required scopes;
4. configure LAN DNS records;
5. point service names to their private IPs;
6. point the Proxmox name to the Proxmox private IP;
7. keep Internet port forwarding disabled if services are LAN-only.

## Verification

```bash
sudo ./install.sh --list
sudo nginx -t
systemctl status nginx
sudo /opt/fedora-server-setup/certbot-venv/bin/certbot certificates
systemctl status fedora-server-certbot-renew.timer
sudo /opt/fedora-server-setup/certbot-venv/bin/certbot renew --dry-run
```

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
