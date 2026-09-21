# Extending the setup

The repository is intentionally modular.

## Add another service

Recommended pattern:

1. Add a new Compose directory under `docker/`.
2. Bind the application only to `127.0.0.1`.
3. Add a dedicated Nginx virtual host under `nginx/`.
4. Add the hostname to `config/domains.conf`.
5. Extend `scripts/40-certificates.sh` with the new SAN/certificate.
6. Extend `install.sh` in dependency order.
7. Extend `scripts/99-verify.sh`.

Example layout:

```text
docker/myservice/compose.yml
nginx/myservice.conf
```

## Keep private data out of Git

Never commit:

- CA private keys
- TLS private keys
- Vaultwarden data
- `.env` files containing secrets
- database files
- access tokens

Use `.gitignore` and store generated runtime state under `/etc/fedora-server-setup/` or `/opt/fedora-server-setup/`.

## Changing hostnames

Edit:

```text
config/domains.conf
```

Then rerun:

```bash
sudo ./install.sh
```

The certificate and Nginx stages are designed to be rerunnable.

## Changing the Fedora IP

Run:

```bash
sudo ./install.sh
```

The network stage asks for the desired static IP. The certificate stage compares the current IP with the certificate SAN and regenerates certificates when needed.

After an IP change, update the corresponding AdGuard records.

## Changing container images

The Compose files deliberately use explicit image variables with defaults. You can create a local `.env` file beside a Compose file to pin a tested image tag.

Example:

```text
PORTAINER_IMAGE=portainer/portainer-ce:lts
VAULTWARDEN_IMAGE=vaultwarden/server:latest
```

Do not commit a local `.env` file unless it contains no secrets.

## Adding external DNS

This repository does not configure AdGuard or OPNsense.

That keeps the Fedora setup independent of the network appliance.

The expected DNS records are:

```text
fedora-server.home -> Fedora IP
portainer.home     -> Fedora IP
vault.home         -> Fedora IP
proxmox.home       -> Proxmox IP
```

## HTTPS trust model

This project uses one local CA and issues leaf certificates for:

- `fedora-server.home`
- `portainer.home`
- `vault.home`

The same certificates also contain the Fedora IP as an IP SAN.

Clients must trust the CA certificate:

```text
/etc/fedora-server-setup/tls/ca.crt
```

Proxmox is intentionally excluded from this CA. Proxmox manages its own HTTPS certificate.
