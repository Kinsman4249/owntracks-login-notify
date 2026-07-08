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
# Cloudflare exclusion runs in two layers, both over HTTPS (curl only):
#   Layer 1 (startup): the published Cloudflare ips-v4/ips-v6 lists AND the
#       full set of prefixes announced by Cloudflare's ASN (AS13335, from
#       RIPEstat) are fetched into a ranges file and matched per-line with
#       grepcidr (IPv4 + IPv6). The published lists are only Cloudflare's
#       customer-facing ranges; the ASN covers everything they announce
#       (WARP, Zero Trust, Spectrum, newer allocations).
#   Layer 2 (per-IP failsafe): immediately before an email would be sent, the
#       candidate IP's ASN is looked up over HTTPS; if it is Cloudflare's ASN
#       the notification is skipped. This only runs for would-be alerts, so
#       lookups are rare. It fails open — a failed/timed-out lookup is treated
#       as non-Cloudflare so a transient outage never suppresses a real alert.
#
# Once an IP is seen, it is ignored for one month before being new again.
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

# Cloudflare ASN failsafe
CF_ASN="${CF_ASN:-13335}"                          # Cloudflare's autonomous system number
ASN_PREFIX_EXPANSION="${ASN_PREFIX_EXPANSION:-1}"  # Layer 1: merge AS<CF_ASN> prefixes at startup
ASN_FAILSAFE="${ASN_FAILSAFE:-1}"                  # Layer 2: per-IP ASN lookup before sending
ASN_LOOKUP_TIMEOUT="${ASN_LOOKUP_TIMEOUT:-3}"      # seconds per per-IP lookup
# Per-IP ASN lookup endpoint; the IP is appended. Defaults to RIPEstat's
# network-info API — same provider as Layer 1, reliably reachable from
# servers. (The previous default, api.iptoasn.com, sits behind Cloudflare's
# WAF, which blocks many datacenter IPs.) Both RIPEstat ({"data":{"asns":[..]}})
# and iptoasn-style ({"as_number":N}) responses are understood.
ASN_LOOKUP_URL="${ASN_LOOKUP_URL:-https://stat.ripe.net/data/network-info/data.json?resource=}"   # IP is appended
RIPESTAT_URL="${RIPESTAT_URL:-https://stat.ripe.net/data/announced-prefixes/data.json?resource=}" # AS<CF_ASN> is appended

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

# --- Dependencies (jq is optional; a grep fallback is used when absent) ---
for cmd in curl awk tail grepcidr; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found. Install with: sudo apt install $cmd" >&2
        exit 1
    fi
done

# --- Setup ---
mkdir -p "$SEEN_IPS_DIR"
mkdir -p "$(dirname "$CF_RANGES_FILE")"

# --- Helpers -----------------------------------------------------------------

# Extract CIDR prefixes from a RIPEstat announced-prefixes JSON payload.
# Uses jq when available, otherwise a whitespace-tolerant grep/sed fallback.
extract_prefixes() {
    local json="$1"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '.data.prefixes[]?.prefix // empty' 2>/dev/null
    else
        printf '%s' "$json" \
            | grep -oE '"prefix"[[:space:]]*:[[:space:]]*"[^"]+"' \
            | sed -E 's/.*:[[:space:]]*"([^"]+)"/\1/'
    fi
}

# Cloudflare CIDR check (grepcidr handles IPv4 + IPv6).
is_cloudflare_ip() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1
    printf '%s\n' "$ip" | grepcidr -f "$CF_RANGES_FILE" >/dev/null 2>&1
}

# Per-IP ASN lookup, cached for the life of the process. Prints the ASN
# (digits) or nothing on failure. Fails silently → caller fails open.
# Understands two response shapes:
#   RIPEstat network-info : {"data":{"asns":["13335"], ...}}
#   iptoasn-style         : {"as_number":13335, ...}
declare -A ASN_CACHE
get_asn() {
    local ip="$1" json asn=""
    [[ -z "$ip" ]] && return 0
    if [[ -n "${ASN_CACHE[$ip]+x}" ]]; then
        printf '%s' "${ASN_CACHE[$ip]}"
        return 0
    fi
    json="$(curl -sf --max-time "$ASN_LOOKUP_TIMEOUT" "${ASN_LOOKUP_URL}${ip}" 2>/dev/null || true)"
    if [[ -n "$json" ]]; then
        if command -v jq >/dev/null 2>&1; then
            asn="$(printf '%s' "$json" \
                   | jq -r '(.data.asns[0] // .as_number // empty) | tostring' 2>/dev/null)"
        else
            # RIPEstat shape first: "asns":["13335", ...]
            asn="$(printf '%s' "$json" \
                   | grep -oE '"asns"[[:space:]]*:[[:space:]]*\[[[:space:]]*"?[0-9]+' \
                   | grep -oE '[0-9]+$' | head -1)"
            # Fallback to iptoasn shape: "as_number":13335
            if [[ -z "$asn" ]]; then
                asn="$(printf '%s' "$json" \
                       | grep -oE '"as_number"[[:space:]]*:[[:space:]]*[0-9]+' \
                       | grep -oE '[0-9]+$' | head -1)"
            fi
        fi
    fi
    # Normalise anything non-numeric (jq null, error text) to empty → fail open.
    [[ "$asn" =~ ^[0-9]+$ ]] || asn=""
    ASN_CACHE[$ip]="$asn"
    printf '%s' "$asn"
}

# True only when the IP's ASN equals CF_ASN. Fail-open: unknown → false (send).
# Calls get_asn directly (not in a subshell) so the cache it populates persists
# into the caller's scope — the tail loop runs in one subshell, so lookups are
# reused across iterations and the skip-log can read ASN_CACHE safely.
is_cloudflare_asn() {
    local ip="$1"
    get_asn "$ip" >/dev/null
    [[ "${ASN_CACHE[$ip]:-}" == "$CF_ASN" ]]
}

# --- Fetch Cloudflare ranges (published + ASN expansion); atomic write --------
TMP_RANGES="$(mktemp)"
trap 'rm -f "$TMP_RANGES" "${TMP_RANGES}.clean"' EXIT

published_ok=0
if curl -sf --max-time 10 https://www.cloudflare.com/ips-v4 >> "$TMP_RANGES" \
   && curl -sf --max-time 10 https://www.cloudflare.com/ips-v6 >> "$TMP_RANGES"; then
    published_ok=1
else
    echo "WARNING: Could not fetch Cloudflare published ips-v4/ips-v6 lists." >&2
fi

# Layer 1: expand Cloudflare's ASN into its full announced-prefix set.
asn_prefix_count=0
if [[ "$ASN_PREFIX_EXPANSION" == "1" ]]; then
    ripe_json="$(curl -sf --max-time 15 "${RIPESTAT_URL}AS${CF_ASN}" 2>/dev/null || true)"
    if [[ -n "$ripe_json" ]]; then
        asn_prefixes="$(extract_prefixes "$ripe_json")"
        if [[ -n "$asn_prefixes" ]]; then
            printf '%s\n' "$asn_prefixes" >> "$TMP_RANGES"
            asn_prefix_count=$(printf '%s\n' "$asn_prefixes" | grep -c '/')
        fi
    fi
    if [[ "$asn_prefix_count" -eq 0 ]]; then
        echo "WARNING: Could not fetch AS${CF_ASN} announced prefixes (Layer 1). Continuing without ASN prefix expansion." >&2
    fi
fi

if [[ "$published_ok" -eq 1 || "$asn_prefix_count" -gt 0 ]]; then
    grep -E '\S' "$TMP_RANGES" | sort -u > "${TMP_RANGES}.clean" || true
    if [[ -s "${TMP_RANGES}.clean" ]]; then
        mv "${TMP_RANGES}.clean" "$CF_RANGES_FILE"
        n="$(wc -l < "$CF_RANGES_FILE" | tr -d ' ')"
        echo "Loaded $n Cloudflare ranges into $CF_RANGES_FILE (published lists + ${asn_prefix_count} AS${CF_ASN} prefixes)."
    fi
elif [[ -s "$CF_RANGES_FILE" ]]; then
    n="$(wc -l < "$CF_RANGES_FILE" | tr -d ' ')"
    echo "WARNING: Could not refresh Cloudflare ranges from any source. Using cached $n ranges from $CF_RANGES_FILE." >&2
else
    echo "ERROR: Failed to fetch Cloudflare ranges and no cache exists at $CF_RANGES_FILE." >&2
    echo "Refusing to start — every Cloudflare-proxied login would generate an email." >&2
    exit 1
fi

# --- Startup self-tests ------------------------------------------------------
# 1.1.1.1 is Cloudflare's public DNS resolver: always within their ranges and
# always AS<CF_ASN>. If the CIDR check misclassifies it, the filter is broken —
# exit loudly. The ASN check only warns (it fails open by design).
if ! is_cloudflare_ip "1.1.1.1"; then
    echo "ERROR: Cloudflare IP self-test failed — 1.1.1.1 was not classified as Cloudflare." >&2
    echo "Check $CF_RANGES_FILE and grepcidr. Refusing to start." >&2
    exit 1
fi
echo "Cloudflare CIDR self-test passed (1.1.1.1 -> CF)."

if [[ "$ASN_FAILSAFE" == "1" ]]; then
    test_asn="$(get_asn "1.1.1.1")"
    if [[ "$test_asn" == "$CF_ASN" ]]; then
        echo "ASN failsafe self-test passed (1.1.1.1 -> AS${test_asn})."
    elif [[ -z "$test_asn" ]]; then
        echo "WARNING: ASN failsafe self-test could not reach ${ASN_LOOKUP_URL} — the failsafe will fail open until it is reachable." >&2
    else
        echo "WARNING: ASN failsafe self-test got AS${test_asn} for 1.1.1.1 (expected AS${CF_ASN}). Check CF_ASN / ASN_LOOKUP_URL." >&2
    fi
fi

echo "Watching $NGINX_LOG for logins to $WATCH_PATH ..."

# --- Tail loop ---------------------------------------------------------------
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

    # Layer 2 final failsafe: ASN lookup right before sending. Runs only for a
    # genuinely new IP that already passed the CIDR + TTL checks, so lookups are
    # rare. We do NOT record CF IPs as seen (no state pollution); the in-process
    # cache prevents repeat lookups for the same IP.
    if [[ "$ASN_FAILSAFE" == "1" ]] && is_cloudflare_asn "$ip"; then
        echo "Skipping $ip — ASN ${ASN_CACHE[$ip]:-?} is Cloudflare (AS${CF_ASN})."
        continue
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
