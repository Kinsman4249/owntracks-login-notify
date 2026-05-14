#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Contributors to owntracks-login-notify
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# OwnTracks login notifier
# Tails the nginx access log and sends an email via smtp2go whenever an
# authenticated user hits the owntracks frontend from a new or expired IP.
#
# Cloudflare IP ranges are fetched fresh at startup and excluded using
# grepcidr (handles IPv4 + IPv6). Once an IP is seen, it is ignored for
# one month before being considered new again.
#
# Config is loaded from environment variables. The systemd unit pulls
# them from /etc/default/owntracks-login-notify — do NOT edit this
# script to set credentials.

set -u

# --- Config (env-only; install.sh writes /etc/default/owntracks-login-notify) ---
NGINX_LOG="${NGINX_LOG:-/var/log/nginx/access.log}"
SMTP2GO_KEY="${SMTP2GO_KEY:-}"
FROM_EMAIL="${FROM_EMAIL:-}"
TO_EMAIL="${TO_EMAIL:-}"
SEEN_IPS_DIR="${SEEN_IPS_DIR:-/var/lib/owntracks/seen_ips}"
IP_TTL="${IP_TTL:-$(( 30 * 24 * 3600 ))}"         # 30 days
WATCH_PATH="${WATCH_PATH:-/owntracks/}"
CF_RANGES_FILE="${CF_RANGES_FILE:-/var/lib/owntracks/cf_ranges.txt}"

# --- Validate config ---
err=0
if [[ -z "$SMTP2GO_KEY" || "$SMTP2GO_KEY" == api-xxx* ]]; then
    echo "ERROR: SMTP2GO_KEY is not set. Edit /etc/default/owntracks-login-notify." >&2
    err=1
fi
if [[ -z "$FROM_EMAIL" || "$FROM_EMAIL" == *example.com ]]; then
    echo "ERROR: FROM_EMAIL is not set. Edit /etc/default/owntracks-login-notify." >&2
    err=1
fi
if [[ -z "$TO_EMAIL" || "$TO_EMAIL" == *example.com ]]; then
    echo "ERROR: TO_EMAIL is not set. Edit /etc/default/owntracks-login-notify." >&2
    err=1
fi
[[ "$err" -ne 0 ]] && exit 1

# --- Dependencies ---
for cmd in curl awk tail grepcidr; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found. Install with: sudo apt install $cmd" >&2
        exit 1
    fi
done

# --- Setup ---
mkdir -p "$SEEN_IPS_DIR"
mkdir -p "$(dirname "$CF_RANGES_FILE")"

# --- Fetch Cloudflare IP ranges to a file (atomic write; fall back to cache) ---
TMP_RANGES="$(mktemp)"
trap 'rm -f "$TMP_RANGES" "${TMP_RANGES}.clean"' EXIT

if curl -sf https://www.cloudflare.com/ips-v4 >> "$TMP_RANGES" \
   && curl -sf https://www.cloudflare.com/ips-v6 >> "$TMP_RANGES"; then
    grep -E '\S' "$TMP_RANGES" > "${TMP_RANGES}.clean" || true
    mv "${TMP_RANGES}.clean" "$CF_RANGES_FILE"
    n="$(wc -l < "$CF_RANGES_FILE" | tr -d ' ')"
    echo "Loaded $n Cloudflare IP ranges into $CF_RANGES_FILE."
elif [[ -s "$CF_RANGES_FILE" ]]; then
    n="$(wc -l < "$CF_RANGES_FILE" | tr -d ' ')"
    echo "WARNING: Could not refresh Cloudflare IP ranges from the API. Using cached $n ranges from $CF_RANGES_FILE." >&2
else
    echo "ERROR: Failed to fetch Cloudflare IP ranges and no cache exists at $CF_RANGES_FILE." >&2
    echo "Refusing to start — every Cloudflare-proxied login would generate an email." >&2
    exit 1
fi

# --- Cloudflare IP check (grepcidr handles IPv4 + IPv6) ---
is_cloudflare_ip() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1
    printf '%s\n' "$ip" | grepcidr -f "$CF_RANGES_FILE" >/dev/null 2>&1
}

# --- Startup self-test ---
# 1.1.1.1 is Cloudflare's public DNS resolver and is always within their announced
# ranges. If our check does not classify it as CF, the filter is broken — exit
# loudly rather than silently sending an alert for every login.
if ! is_cloudflare_ip "1.1.1.1"; then
    echo "ERROR: Cloudflare IP self-test failed — 1.1.1.1 was not classified as Cloudflare." >&2
    echo "Check $CF_RANGES_FILE and grepcidr. Refusing to start." >&2
    exit 1
fi
echo "Cloudflare IP filter self-test passed (1.1.1.1 -> CF)."

echo "Watching $NGINX_LOG for logins to $WATCH_PATH ..."

# --- Tail loop ---
# -F (vs -f) handles log rotation automatically.
tail -F -n 0 "$NGINX_LOG" | while read -r line; do

    # nginx combined log format: $1=ip $3=user $7=path $9=status
    ip=$(echo "$line"     | awk '{print $1}')
    user=$(echo "$line"   | awk '{print $3}')
    path=$(echo "$line"   | awk '{print $7}')
    status=$(echo "$line" | awk '{print $9}')

    [[ "$status" != "200" ]] && continue
    [[ "$path" != ${WATCH_PATH}* && "$path" != "$WATCH_PATH" ]] && continue
    [[ "$user" == "-" ]] && continue
    is_cloudflare_ip "$ip" && continue

    # Build per-user/ip file path with sanitised components to avoid path traversal.
    # IPv6 needs ':' in the allowed set.
    safe_user=$(echo "$user" | tr -cd '[:alnum:]_-')
    safe_ip=$(echo "$ip"     | tr -cd '[:alnum:].:_-')
    IP_FILE="$SEEN_IPS_DIR/${safe_user}_${safe_ip}"

    now=$(date +%s)
    if [[ -f "$IP_FILE" ]]; then
        last_seen=$(cat "$IP_FILE")
        age=$(( now - last_seen ))
        [[ "$age" -lt "$IP_TTL" ]] && continue
    fi

    # Update timestamp BEFORE the email so a failed curl doesn't spam-loop.
    echo "$now" > "$IP_FILE"

    curl -s -X POST https://api.smtp2go.com/v3/email/send \
        -H "Content-Type: application/json" \
        -d "{
            \"api_key\": \"$SMTP2GO_KEY\",
            \"sender\": \"$FROM_EMAIL\",
            \"to\": [\"$TO_EMAIL\"],
            \"subject\": \"OwnTracks login: $user from $ip\",
            \"text_body\": \"Login detected\nUser: $user\nIP: $ip\"
        }" >/dev/null

    echo "Email sent for $user from $ip"
done
