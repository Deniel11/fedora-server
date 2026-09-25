# Fedora Server – Cockpit / Proxmox reverse-proxy fixes

Ez a csomag a `Deniel11/fedora-server` repo jelenlegi `main` ágához készült módosított fájlokat tartalmazza.

Módosított fájlok:
- `config/cockpit.conf`
- `config/fedora-server.nginx.conf`
- `config/proxmox.nginx.conf`
- `scripts/02-proxmox.sh`
- `scripts/99-verify.sh`

DNS architektúra:
- `fedora-server.home` -> Fedora Server IP
- `proxmox.home` -> Fedora Server IP
- `vault.home` -> Fedora Server IP
- `portainer.home` -> Fedora Server IP
- `joplin.home` -> Fedora Server IP

A Proxmox valódi backend IP-je nem kerül DNS-be. Az interaktívan bekért IP:
`/etc/fedora-server-setup/proxmox.env`

A kliensoldali Proxmox cím:
`https://proxmox.home`

A Fedora Nginx innen továbbít:
`https://<PROXMOX_IP>:8006`

Telepítés után érdemes:
1. `nginx -t`
2. `systemctl reload nginx`
3. `./install.sh` / a repo saját frissítési folyamatának megfelelő futtatása
4. `./scripts/99-verify.sh`

Megjegyzés: a repo többi, már helyes módosítását nem másoltam újra ebbe a csomagba; ez a csomag csak a jelenlegi GitHub állapothoz képest szükséges fájlokat tartalmazza.
