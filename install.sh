#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Contributors to owntracks-login-notify
#
# install.sh — installs or upgrades owntracks-login-notify and registers
# the systemd service. Safe to re-run; preserves existing config.
#
# Usage: sudo bash install.sh [--yes]
#
#   --yes / -y / --non-interactive
#       Do not prompt. Fail if any required value is missing or still a
#       placeholder. Useful for unattended / CI runs. You can also pass
#       values via environment variables:
#         SMTP2GO_KEY, FROM_EMAIL, TO_EMAIL,
#         NGINX_LOG, WATCH_PATH, IP_TTL, SEEN_IPS_DIR, CF_RANGES_FILE
#
# Discovery precedence per value:
#   1. Environment variable already set in this shell (caller override)
#   2. Existing /etc/default/owntracks-login-notify
#   3. Inline config parsed from the previously-installed
#      /usr/local/bin/owntracks-login-notify.sh (migration)
#   4. Documented default

set -euo pipefail

SCRIPT_SRC="owntracks-login-notify.sh"
SCRIPT_DST="/usr/local/bin/owntracks-login-notify.sh"
SERVICE_SRC="owntracks-login-notify.service"
SERVICE_DST="/etc/systemd/system/owntracks-login-notify.service"
CONFIG_DST="/etc/default/owntracks-login-notify"
SEEN_IPS_DIR_DEFAULT="/var/lib/owntracks/seen_ips"
CF_RANGES_FILE_DEFAULT="/var/lib/owntracks/cf_ranges.txt"

NON_INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y|--non-interactive) NON_INTERACTIVE=1 ;;
        --help|-h)
            cat <<'EOF'
Usage: sudo bash install.sh [--yes]

  --yes, -y, --non-interactive
        Do not prompt. Fail if any required value is missing.
        Pass values via env: SMTP2GO_KEY, FROM_EMAIL, TO_EMAIL,
        NGINX_LOG, WATCH_PATH, IP_TTL, SEEN_IPS_DIR, CF_RANGES_FILE.

Re-running this script on an existing install:
  - Loads current config from /etc/default/owntracks-login-notify
    (or migrates inline config from the old script if that file does
    not exist yet).
  - Prompts only for values that are missing or still placeholders,
    showing the current value as the default.
  - Stops the service before swapping files and restarts after.
EOF
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $arg" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root or with sudo." >&2
    exit 1
fi

# --- Dependency check ---
MISSING=()
for cmd in curl awk tail grepcidr systemctl install; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done
if [[ "${#MISSING[@]}" -gt 0 ]]; then
    echo "ERROR: Missing required commands: ${MISSING[*]}" >&2
    echo "Install with: sudo apt install ${MISSING[*]}" >&2
    exit 1
fi

# --- Sanity check source files ---
for f in "$SCRIPT_SRC" "$SERVICE_SRC"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Required source file not found: $f" >&2
        echo "Run this script from the repository root." >&2
        exit 1
    fi
done

# --- Detect existing install ---
# Version marker was introduced in 1.3.0; older installs show as "pre-1.3.0".
get_version_from() { { grep -m1 '^VERSION=' "$1" 2>/dev/null || true; } | cut -d'"' -f2; }
NEW_VERSION="$(get_version_from "$SCRIPT_SRC")"
EXISTING=0
if [[ -f "$SCRIPT_DST" || -f "$SERVICE_DST" || -f "$CONFIG_DST" ]]; then
    EXISTING=1
    OLD_VERSION="$(get_version_from "$SCRIPT_DST")"
    echo "Existing install detected (v${OLD_VERSION:-pre-1.3.0}) — upgrading to v${NEW_VERSION:-unknown}."
else
    echo "Fresh install of owntracks-login-notify v${NEW_VERSION:-unknown}."
fi

# --- Config discovery ---
declare -A CFG=(
    [SMTP2GO_KEY]=""
    [FROM_EMAIL]=""
    [TO_EMAIL]=""
    [NGINX_LOG]="/var/log/nginx/access.log"
    [WATCH_PATH]="/owntracks/"
    [IP_TTL]="2592000"
    [SEEN_IPS_DIR]="$SEEN_IPS_DIR_DEFAULT"
    [CF_RANGES_FILE]="$CF_RANGES_FILE_DEFAULT"
    [CF_ASN]="13335"
    [ASN_PREFIX_EXPANSION]="1"
    [ASN_FAILSAFE]="1"
    [ASN_LOOKUP_TIMEOUT]="3"
    [ASN_LOOKUP_URL]="https://stat.ripe.net/data/network-info/data.json?resource="
    [RIPESTAT_URL]="https://stat.ripe.net/data/announced-prefixes/data.json?resource="
)

# Snapshot caller env (precedence step 1 — applied last so it wins).
declare -A ENV_OVERRIDE=()
for k in "${!CFG[@]}"; do
    if [[ -n "${!k:-}" ]]; then
        ENV_OVERRIDE[$k]="${!k}"
    fi
done

# Step 2: existing /etc/default/owntracks-login-notify
if [[ -f "$CONFIG_DST" ]]; then
    echo "Loading existing config from $CONFIG_DST"
    # shellcheck disable=SC1090
    set -a; source "$CONFIG_DST"; set +a
    for k in "${!CFG[@]}"; do
        v="${!k:-}"
        [[ -n "$v" ]] && CFG[$k]="$v"
    done
fi

# Step 3: parse old script for inline config (only if no config file existed).
# Handles common forms:
#   KEY="value"
#   KEY='value'
#   KEY=value
#   KEY="${KEY:-value}"
parse_old_script() {
    local key="$1" file="$2" v
    v=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null \
        | head -n1 \
        | sed -E "s/^[[:space:]]*${key}=//" \
        | sed -E 's/^"([^"]*)".*$/\1/' \
        | sed -E "s/^'([^']*)'.*$/\1/" \
        | sed -E 's/[[:space:]]*#.*$//' )
    # Strip the "${KEY:-default}" wrapper if present.
    if [[ "$v" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:-(.*)\}$ ]]; then
        v="${BASH_REMATCH[1]}"
        v="${v%\"}"; v="${v#\"}"
        v="${v%\'}"; v="${v#\'}"
    fi
    printf '%s' "$v"
}

if [[ -f "$SCRIPT_DST" && ! -f "$CONFIG_DST" ]]; then
    echo "Migrating inline config from previous version of $SCRIPT_DST"
    for k in SMTP2GO_KEY FROM_EMAIL TO_EMAIL NGINX_LOG WATCH_PATH IP_TTL SEEN_IPS_DIR CF_RANGES_FILE; do
        v="$(parse_old_script "$k" "$SCRIPT_DST")"
        [[ -n "$v" ]] && CFG[$k]="$v"
    done
fi

# Step 1 applied last: caller env wins over file/migrated values.
for k in "${!ENV_OVERRIDE[@]}"; do
    CFG[$k]="${ENV_OVERRIDE[$k]}"
done

# --- Helpers ---
is_placeholder() {
    local k="$1" v="$2"
    case "$k" in
        SMTP2GO_KEY)         [[ -z "$v" || "$v" == api-xxx* ]] ;;
        FROM_EMAIL|TO_EMAIL) [[ -z "$v" || "$v" == *example.com ]] ;;
        *)                   [[ -z "$v" ]] ;;
    esac
}

mask_secret() {
    local v="$1"
    local n=${#v}
    if (( n <= 8 )); then
        printf '***'
    else
        printf '%s***%s' "${v:0:4}" "${v: -4}"
    fi
}

prompt_for() {
    local k="$1" label="$2" reply current
    current="${CFG[$k]}"

    if (( NON_INTERACTIVE )); then
        if is_placeholder "$k" "$current"; then
            echo "ERROR: $k is required and was not provided (running in --yes / non-interactive mode)." >&2
            echo "Pass it via env: $k=... sudo -E bash install.sh --yes" >&2
            exit 1
        fi
        return
    fi

    if [[ -n "$current" ]] && ! is_placeholder "$k" "$current"; then
        local display="$current"
        [[ "$k" == "SMTP2GO_KEY" ]] && display="$(mask_secret "$current")"
        read -r -p "$label [$display]: " reply
        if [[ -n "$reply" ]]; then
            CFG[$k]="$reply"
        fi
    else
        while :; do
            read -r -p "$label: " reply
            if [[ -n "$reply" ]] && ! is_placeholder "$k" "$reply"; then
                CFG[$k]="$reply"
                break
            fi
            echo "  (value cannot be empty or a placeholder; try again)"
        done
    fi
}

# --- Prompts ---
echo
echo "Configuring owntracks-login-notify (press ENTER to keep existing values)"
echo
prompt_for SMTP2GO_KEY "smtp2go API key"
prompt_for FROM_EMAIL  "From email (must be verified in smtp2go)"
prompt_for TO_EMAIL    "To email (notification recipient)"
prompt_for NGINX_LOG   "nginx access log path"
prompt_for WATCH_PATH  "URL path prefix to watch (trailing slash)"

# --- Stop service before swapping files ---
if systemctl list-unit-files 2>/dev/null | grep -q '^owntracks-login-notify\.service'; then
    if systemctl is-active --quiet owntracks-login-notify; then
        echo
        echo "Stopping running service ..."
        systemctl stop owntracks-login-notify
    fi
fi

# --- Install/upgrade files ---
echo
echo "Installing script to $SCRIPT_DST"
install -m 0755 "$SCRIPT_SRC" "$SCRIPT_DST"

echo "Installing service unit to $SERVICE_DST"
install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"

# --- Write config file (chmod 600 — holds the API key) ---
echo "Writing config to $CONFIG_DST (root-only, chmod 600)"
TMP_CFG="$(mktemp)"
chmod 600 "$TMP_CFG"
cat > "$TMP_CFG" <<EOF
# /etc/default/owntracks-login-notify
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Loaded by the systemd service via EnvironmentFile=.
# Mode 0600 because this contains the smtp2go API key.

SMTP2GO_KEY="${CFG[SMTP2GO_KEY]}"
FROM_EMAIL="${CFG[FROM_EMAIL]}"
TO_EMAIL="${CFG[TO_EMAIL]}"

NGINX_LOG="${CFG[NGINX_LOG]}"
WATCH_PATH="${CFG[WATCH_PATH]}"
IP_TTL=${CFG[IP_TTL]}
SEEN_IPS_DIR="${CFG[SEEN_IPS_DIR]}"
CF_RANGES_FILE="${CFG[CF_RANGES_FILE]}"

# Cloudflare ASN failsafe (see README / owntracks-login-notify.env.example)
CF_ASN=${CFG[CF_ASN]}
ASN_PREFIX_EXPANSION=${CFG[ASN_PREFIX_EXPANSION]}
ASN_FAILSAFE=${CFG[ASN_FAILSAFE]}
ASN_LOOKUP_TIMEOUT=${CFG[ASN_LOOKUP_TIMEOUT]}
ASN_LOOKUP_URL="${CFG[ASN_LOOKUP_URL]}"
RIPESTAT_URL="${CFG[RIPESTAT_URL]}"
EOF
install -m 0600 "$TMP_CFG" "$CONFIG_DST"
rm -f "$TMP_CFG"

# --- State dirs ---
mkdir -p "${CFG[SEEN_IPS_DIR]}"
mkdir -p "$(dirname "${CFG[CF_RANGES_FILE]}")"

# --- Reload + start ---
echo "Reloading systemd ..."
systemctl daemon-reload

echo "Enabling and starting service ..."
systemctl enable --now owntracks-login-notify

# --- Post-install diagnostics --------------------------------------------------
# Quick smoke tests of every external touchpoint the daemon relies on. A FAIL
# here never aborts the install (the daemon is designed to degrade gracefully);
# each failure prints concrete pointers on what to look at first.
DIAG_FAILS=0
diag_ok()   { printf '  OK    %s\n' "$1"; }
diag_fail() {
    DIAG_FAILS=$((DIAG_FAILS+1))
    printf '  FAIL  %s\n' "$1"; shift
    local n
    for n in "$@"; do printf '        -> %s\n' "$n"; done
}

echo
echo "== Post-install diagnostics =="
echo "  Installed version: v$(get_version_from "$SCRIPT_DST")"

# 1. nginx access log readable
if [[ -r "${CFG[NGINX_LOG]}" ]]; then
    diag_ok "nginx log readable: ${CFG[NGINX_LOG]}"
else
    diag_fail "nginx log not readable: ${CFG[NGINX_LOG]}" \
        "Check the path exists: ls -l ${CFG[NGINX_LOG]}" \
        "Using a vhost-specific access log? Set NGINX_LOG in $CONFIG_DST and restart the service" \
        "Until this path is right, the daemon tails nothing and no login will ever be detected"
fi

# 2. Cloudflare published IP lists
cf_v4="$(curl -sf --max-time 8 https://www.cloudflare.com/ips-v4 2>/dev/null || true)"
cf_v6="$(curl -sf --max-time 8 https://www.cloudflare.com/ips-v6 2>/dev/null || true)"
v4n="$(printf '%s' "$cf_v4" | { grep -c '/' || true; })"
v6n="$(printf '%s' "$cf_v6" | { grep -c '/' || true; })"
if [[ "$v4n" -gt 0 && "$v6n" -gt 0 ]]; then
    diag_ok "Cloudflare published lists reachable ($v4n v4 + $v6n v6 ranges)"
else
    diag_fail "Cloudflare published lists not reachable (www.cloudflare.com/ips-v4, /ips-v6)" \
        "Check outbound HTTPS/DNS: curl -v https://www.cloudflare.com/ips-v4" \
        "The daemon falls back to the cached ranges at ${CFG[CF_RANGES_FILE]} if one exists" \
        "With no cache AND no fetch, the service refuses to start (see journalctl)"
fi

# 3. Layer 1 — RIPEstat announced prefixes for AS<CF_ASN>
if [[ "${CFG[ASN_PREFIX_EXPANSION]}" == "1" ]]; then
    ripe="$(curl -sf --max-time 10 "${CFG[RIPESTAT_URL]}AS${CFG[CF_ASN]}" 2>/dev/null || true)"
    pfx_n="$(printf '%s' "$ripe" | { grep -o '"prefix"' || true; } | wc -l | tr -d ' ')"
    if [[ "$pfx_n" -gt 0 ]]; then
        diag_ok "RIPEstat (Layer 1) reachable — $pfx_n AS${CFG[CF_ASN]} prefixes announced"
    else
        diag_fail "RIPEstat (Layer 1) returned no prefixes for AS${CFG[CF_ASN]}" \
            "Check reachability: curl -v '${CFG[RIPESTAT_URL]}AS${CFG[CF_ASN]}'" \
            "Layer 1 will warn at startup and run with only the published lists" \
            "If your network blocks stat.ripe.net, override RIPESTAT_URL in $CONFIG_DST"
    fi
else
    diag_ok "Layer 1 (ASN prefix expansion) disabled by config — skipped"
fi

# 4. Layer 2 — per-IP ASN lookup (1.1.1.1 must resolve to AS<CF_ASN>)
if [[ "${CFG[ASN_FAILSAFE]}" == "1" ]]; then
    asn_json="$(curl -sf --max-time "${CFG[ASN_LOOKUP_TIMEOUT]}" "${CFG[ASN_LOOKUP_URL]}1.1.1.1" 2>/dev/null || true)"
    # Accept both RIPEstat ("asns":["N"]) and iptoasn ("as_number":N) shapes.
    asn="$(printf '%s' "$asn_json" | { grep -oE '"asns"[[:space:]]*:[[:space:]]*\[[[:space:]]*"?[0-9]+' || true; } | { grep -oE '[0-9]+$' || true; } | head -1)"
    if [[ -z "$asn" ]]; then
        asn="$(printf '%s' "$asn_json" | { grep -oE '"as_number"[[:space:]]*:[[:space:]]*[0-9]+' || true; } | { grep -oE '[0-9]+$' || true; } | head -1)"
    fi
    if [[ "$asn" == "${CFG[CF_ASN]}" ]]; then
        diag_ok "ASN lookup (Layer 2) reachable — 1.1.1.1 -> AS${asn}"
    elif [[ -z "$asn" ]]; then
        diag_fail "ASN lookup (Layer 2) unreachable or unparseable: ${CFG[ASN_LOOKUP_URL]}" \
            "Check reachability: curl -v '${CFG[ASN_LOOKUP_URL]}1.1.1.1'" \
            "Slow network? Raise ASN_LOOKUP_TIMEOUT in $CONFIG_DST (currently ${CFG[ASN_LOOKUP_TIMEOUT]}s)" \
            "Not fatal: Layer 2 fails open (alerts still send), and Layer 1 already covers the full ASN"
    else
        diag_fail "ASN lookup returned AS${asn} for 1.1.1.1 (expected AS${CFG[CF_ASN]})" \
            "Endpoint may use a different response format — check: curl '${CFG[ASN_LOOKUP_URL]}1.1.1.1'" \
            "If you changed CF_ASN or ASN_LOOKUP_URL in $CONFIG_DST, verify they agree"
    fi
else
    diag_ok "Layer 2 (per-IP ASN failsafe) disabled by config — skipped"
fi

# 5. smtp2go API + key validation (no test email is sent: empty recipient list)
smtp_resp="$(curl -s --max-time 8 -X POST https://api.smtp2go.com/v3/email/send \
    -H "Content-Type: application/json" \
    -d "{\"api_key\":\"${CFG[SMTP2GO_KEY]}\",\"to\":[],\"sender\":\"${CFG[FROM_EMAIL]}\",\"subject\":\"\",\"text_body\":\"\"}" \
    2>/dev/null || true)"
if [[ -z "$smtp_resp" ]]; then
    diag_fail "smtp2go API unreachable (api.smtp2go.com)" \
        "Check outbound HTTPS/DNS: curl -v https://api.smtp2go.com/v3/email/send" \
        "Until this is reachable, login alerts cannot be delivered"
elif printf '%s' "$smtp_resp" | grep -qiE 'api.?_?key|NONEXISTENT|unauthori'; then
    diag_fail "smtp2go rejected the API key" \
        "Response: $(printf '%s' "$smtp_resp" | head -c 200)" \
        "Re-check SMTP2GO_KEY in $CONFIG_DST (or re-run this installer and re-enter it)" \
        "Keys are managed at app.smtp2go.com under Settings -> API Keys"
else
    diag_ok "smtp2go API reachable, API key accepted (no test email sent)"
fi

# 6. Seen-IPs state dir writable
if touch "${CFG[SEEN_IPS_DIR]}/.diag_write_test" 2>/dev/null; then
    rm -f "${CFG[SEEN_IPS_DIR]}/.diag_write_test"
    diag_ok "seen-IPs dir writable: ${CFG[SEEN_IPS_DIR]}"
else
    diag_fail "seen-IPs dir not writable: ${CFG[SEEN_IPS_DIR]}" \
        "Check mount/permissions: ls -ld ${CFG[SEEN_IPS_DIR]}" \
        "Without it every login re-alerts on each occurrence (no 30-day memory)"
fi

echo
if [[ "$DIAG_FAILS" -eq 0 ]]; then
    echo "All diagnostics passed."
else
    echo "$DIAG_FAILS diagnostic(s) need attention — see the notes above. (Install itself completed.)"
fi

# --- Verify ---
sleep 2
if systemctl is-active --quiet owntracks-login-notify; then
    echo
    if (( EXISTING )); then
        echo "owntracks-login-notify v${NEW_VERSION:-?} upgraded and active."
    else
        echo "owntracks-login-notify v${NEW_VERSION:-?} installed and active."
    fi
    echo
    echo "View logs:    sudo journalctl -u owntracks-login-notify -f"
    echo "Edit config:  sudo \$EDITOR $CONFIG_DST  (then sudo systemctl restart owntracks-login-notify)"
else
    echo
    echo "WARNING: service did not become active. Inspect with:" >&2
    echo "  sudo systemctl status owntracks-login-notify --no-pager" >&2
    echo "  sudo journalctl -u owntracks-login-notify -n 50 --no-pager" >&2
    exit 1
fi
