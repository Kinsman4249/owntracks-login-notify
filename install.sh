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
EXISTING=0
if [[ -f "$SCRIPT_DST" || -f "$SERVICE_DST" || -f "$CONFIG_DST" ]]; then
    EXISTING=1
    echo "Existing install detected — will upgrade in place."
else
    echo "Fresh install."
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

# --- Verify ---
sleep 2
if systemctl is-active --quiet owntracks-login-notify; then
    echo
    if (( EXISTING )); then
        echo "owntracks-login-notify upgraded and active."
    else
        echo "owntracks-login-notify installed and active."
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
