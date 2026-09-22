# Extending the setup

Applications are intentionally self-contained. The central installer discovers application modules automatically.

## Add a Docker application

Create:

```text
apps/myservice/
├── app.conf
├── compose.yml
├── install.sh
├── verify.sh
└── nginx.conf
```

Add the application's visible domain and host port to:

```text
config/domains.conf
```

For example:

```bash
MYSERVICE_DOMAIN="myservice.home"
MYSERVICE_PORT="8090"
```

Then define the module metadata in `app.conf`:

```bash
APP_ID="myservice"
APP_NAME="My Service"
APP_DOMAIN="${MYSERVICE_DOMAIN}"
APP_PORT="${MYSERVICE_PORT}"
APP_CONTAINER="myservice"
APP_TLS_NAME="myservice"
APP_NGINX_ENABLED="true"
APP_CERTIFICATE_ENABLED="true"
APP_HEALTHCHECK_URL="http://127.0.0.1:${APP_PORT}/"
```

The application will automatically appear in:

```bash
sudo ./install.sh
```

and:

```bash
sudo ./install.sh --list
```

No change to `install.sh`, `40-certificates.sh` or `05-nginx.sh` is required.

## Application contract

Every application should implement:

```text
is_installed
install
is_running
verify
```

The common implementation is provided by `scripts/00-common.sh`.

The application module provides the application-specific installation and verification details.

### Idempotency

An already healthy application should not be recreated on every installer run.

Use:

```bash
if app_is_installed myservice && app_is_running myservice; then
    log "My Service is already installed and running; skipping container recreation."
else
    app_compose_up myservice
fi
```

Mark a successfully configured application with:

```bash
touch "$(app_runtime_dir myservice)/.installed"
```

## Compose requirements

Applications must run through Docker Compose.

Bind host ports to localhost whenever possible:

```yaml
ports:
  - "127.0.0.1:${MYSERVICE_PORT}:8080"
```

Do not publish application ports directly to the LAN unless there is a deliberate reason to do so.

The central configuration is responsible for the host port.

## Nginx

Use placeholders in `nginx.conf`:

```text
__APP_DOMAIN__
__APP_PORT__
__APP_TLS_NAME__
```

The central Nginx stage replaces them and writes the result to:

```text
/etc/nginx/conf.d/myservice.conf
```

If an application does not need Nginx, set:

```bash
APP_NGINX_ENABLED="false"
```

## Certificates

If an application is served over HTTPS through Nginx, use:

```bash
APP_CERTIFICATE_ENABLED="true"
```

The central certificate stage automatically creates or refreshes the certificate for `APP_DOMAIN` and the current Fedora IP.

For applications that do not need a certificate, set:

```bash
APP_CERTIFICATE_ENABLED="false"
```

## Storage

Keep runtime data outside the Git repository.

Use:

```text
/opt/fedora-server-apps/<app>/
```

for application data and Compose runtime files.

Do not put passwords, databases, uploaded files or private keys into Git.

For storage-heavy applications such as Immich, Jellyfin or file management, prefer a dedicated storage path when the hardware is ready.

## Domain and port collision checks

The central configuration validator automatically checks for duplicate domains and host ports.

Do not work around a collision by hardcoding a second port inside `compose.yml`. Change the central configuration instead.

## Secrets

If an application needs a secret:

- generate it on the server
- store it under `/etc/fedora-server-setup` or `/opt/fedora-server-apps`
- use restrictive permissions
- never commit it to Git

Joplin is the reference example: its PostgreSQL password is generated or entered interactively and stored in the runtime `.env` file with mode `600`.

## Existing data migration

If an application already exists in an older repository layout, migrate its data before starting the new Compose project.

Do not delete the old data automatically unless the migration has been verified.

## Testing a new application

At minimum:

```bash
bash -n install.sh
bash -n scripts/*.sh
bash -n apps/myservice/*.sh
```

Then use ShellCheck:

```bash
shellcheck install.sh scripts/*.sh apps/*/*.sh
```

Finally test:

```bash
sudo ./install.sh --app myservice
sudo ./install.sh --app myservice
```

The second run should be a no-op for a healthy application.
