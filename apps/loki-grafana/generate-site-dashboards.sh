#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/00-common.sh"

require_root
require_fedora
load_config
load_domain_state
ensure_dirs
load_app_config "loki-grafana"

runtime="$(app_runtime_dir loki-grafana)"
template="$(app_dir loki-grafana)/provisioning/dashboards/nginx-site-analytics.template"
dashboard_dir="${runtime}/provisioning/dashboards"
alloy_config="${runtime}/config.alloy"

[[ -f "$template" ]] || die "Nginx site dashboard template is missing: ${template}"
install -d -m 0750 "$dashboard_dir"
find "$dashboard_dir" -maxdepth 1 -type f -name 'nginx-site-*.json' -delete

cat > "$alloy_config" <<'EOF_ACCESS'
logging {
  level = "info"
}

local.file_match "nginx_access" {
  path_targets = [
    {
      __path__ = "/var/log/nginx/access.log*",
      job = "nginx",
      log_type = "access",
    },
EOF_ACCESS

cat > "${alloy_config}.error" <<'EOF_ERROR'
local.file_match "nginx_error" {
  path_targets = [
    {
      __path__ = "/var/log/nginx/error.log*",
      job = "nginx",
      log_type = "error",
    },
EOF_ERROR

while IFS= read -r site_app_id; do
    [[ -n "$site_app_id" ]] || continue
    [[ "$site_app_id" == "loki-grafana" ]] && continue
    load_app_config "$site_app_id" || continue
    [[ "${APP_NGINX_ENABLED:-true}" == "true" ]] || continue
    [[ -f "$(app_dir "$site_app_id")/nginx.conf" ]] || continue

    site_domain="${APP_CANONICAL_DOMAIN:-${APP_DOMAIN:-}}"
    [[ -n "$site_domain" ]] || continue
    site_id="${site_app_id//[^a-zA-Z0-9_-]/-}"

    printf '    { __path__ = "/var/log/nginx/%s-access.log", job = "nginx", log_type = "access", site = "%s" },\n' "$site_id" "$site_id" >> "$alloy_config"
    printf '    { __path__ = "/var/log/nginx/%s-error.log", job = "nginx", log_type = "error", site = "%s" },\n' "$site_id" "$site_id" >> "${alloy_config}.error"

    sed \
        -e "s|__SITE_ID__|${site_id}|g" \
        -e "s|__SITE_DOMAIN__|${site_domain}|g" \
        "$template" > "${dashboard_dir}/nginx-site-${site_id}.json"
    chmod 0644 "${dashboard_dir}/nginx-site-${site_id}.json"
done < <(app_ids)

cat >> "$alloy_config" <<'EOF_ACCESS_END'
  ]
  sync_period = "5s"
}

EOF_ACCESS_END

cat "${alloy_config}.error" >> "$alloy_config"
rm -f "${alloy_config}.error"

cat >> "$alloy_config" <<'EOF_ERROR_END'
  ]
  sync_period = "5s"
}

loki.source.file "nginx_access" {
  targets       = local.file_match.nginx_access.targets
  forward_to    = [loki.write.default.receiver]
  tail_from_end = false
}

loki.source.file "nginx_error" {
  targets       = local.file_match.nginx_error.targets
  forward_to    = [loki.write.default.receiver]
  tail_from_end = false
}

loki.write "default" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
EOF_ERROR_END

chmod 0644 "$alloy_config"
