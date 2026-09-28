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

Add the application's default visible domain and host port to `config/domains.conf`.

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

The domain is automatically rewritten in public-domain mode. Do not hardcode `.home.example.com` into application modules.

## Nginx

Use these placeholders in `nginx.conf`:

```text
__APP_DOMAIN__
__APP_PORT__
__APP_TLS_NAME__
__APP_CERTIFICATE__
__APP_CERTIFICATE_KEY__
```

The central Nginx stage writes the final configuration to:

```text
/etc/nginx/conf.d/myservice.conf
```

`__APP_CERTIFICATE__` and `__APP_CERTIFICATE_KEY__` are local-CA paths in local mode and `/etc/letsencrypt/live/<hostname>/...` paths in public mode. This keeps application modules independent of the selected TLS implementation.

If an application does not need Nginx, set:

```bash
APP_NGINX_ENABLED="false"
```

## Certificates

If an application is served over HTTPS through Nginx, use:

```bash
APP_CERTIFICATE_ENABLED="true"
```

The central certificate stage automatically creates/renews the certificate for `APP_DOMAIN`.

In local mode the repository-generated CA is used. In public mode Let's Encrypt ACME HTTP-01 is used.

The application module must not generate its own certificate.

## Domain configuration

The installer persists the selected mode in:

```text
/etc/fedora-server-setup/domain.env
```

A module receives its final `APP_DOMAIN` after `load_domain_state` is called. Application `install.sh` and `verify.sh` scripts that use domain variables should therefore call:

```bash
load_config
load_domain_state
```

before `load_app_config`.

## Idempotency

An already healthy application should not be recreated on every installer run.

Use:

```bash
if app_is_installed myservice && app_is_running myservice && app_is_current myservice; then
    log "My Service is already installed and running; skipping container recreation."
else
    app_compose_up myservice
fi
```

Mark a successfully configured application with:

```bash
app_write_state myservice
```

## Compose requirements

Applications must run through Docker Compose.

Bind host ports to localhost whenever possible:

```yaml
ports:
  - "127.0.0.1:${MYSERVICE_PORT}:8080"
```

Do not publish application ports directly to the LAN unless there is a deliberate reason to do so.

## Storage and secrets

Keep runtime data outside the Git repository, preferably under:

```text
/opt/fedora-server-apps/<app>/
```

Never commit passwords, databases, uploaded files, DNS credentials, ACME credentials, or private keys to Git.

## Testing

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

Finally test installation twice. The second run should not ask the domain/TLS questions again unless `--reconfigure-domain` is supplied.
