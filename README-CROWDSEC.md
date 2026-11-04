# Fedora Server CrowdSec integration

Apply from the root of your local `fedora-server` checkout:

```bash
cp /path/to/extracted/scripts/crowdsec.sh scripts/crowdsec.sh
chmod 750 scripts/crowdsec.sh
git apply /path/to/extracted/patches/install.sh.patch
cp /path/to/extracted/README-CROWDSEC.md README-CROWDSEC.md
```

The existing `scripts/05-nginx.sh` must retain its optional `--offer` block
after Nginx has successfully reloaded/started. That makes the one-time offer
appear as part of the normal install/update workflow.

Normal management is now through the existing installer:

```bash
sudo ./install.sh
```

Choose menu option **9) CrowdSec management**. No separate CrowdSec command
is needed for normal use.

The management submenu can install/configure, refresh log discovery, show
status/metrics, or remove this repository integration. The main installer
also offers Crowdsec after the Nginx stage if no decision has been saved.

The script discovers absolute Nginx `access_log` paths from `nginx -T`.
Nginx variables in paths are converted to glob wildcards, such as
`$host.access.log` -> `*.access.log`. It skips `off`, syslog destinations,
relative paths, and unsupported paths. The generated CrowdSec file enables
`discovery_poll_enable` with a 30-second interval; a systemd timer rechecks
Nginx configuration every five minutes.

The script installs `crowdsecurity/nginx`, validates with `crowdsec -t`,
and only then restarts CrowdSec. It always ensures the service is enabled and
running, even if the acquisition file did not change. The systemd timer calls
a stable copy at `/opt/fedora-server-setup/crowdsec.sh`, not the original
checkout path.

Detection only: no bouncer, OPNsense rules, or automatic IP blocking.

Validate before running on the server:

```bash
bash -n scripts/crowdsec.sh
bash -n scripts/05-nginx.sh
bash -n install.sh
git diff --check
sudo nginx -t
sudo crowdsec -t
```

Inspect the generated acquisition file and CrowdSec metrics after installation.
