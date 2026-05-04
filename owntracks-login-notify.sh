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
# Tails the nginx access log and sends an email via smtp2go
# whenever an authenticated user hits the owntracks frontend from a new or expired IP.
# Cloudflare IP ranges are fetched from the official API at startup and excluded.
# Once an IP is seen, it is ignored for one month before being considered new again.

# --- Config ---
# These can be overridden by environment variables or by editing this file directly.
NGINX_LOG="${NGINX_LOG:-/var/log/nginx/access.log}"       # update if using a vhost-specific log
SMTP2GO_KEY="${SMTP2GO_KEY:-api-xxxxxxxxxxxxxxxxxxxx}"    # your smtp2go API key
FROM_EMAIL="${FROM_EMAIL:-you@example.com}"                # must be a verified sender in smtp2go
TO_EMAIL="${TO_EMAIL:-you@example.com}"                    # where to send the notification
SEEN_IPS_DIR="${SEEN_IPS_DIR:-/var/lib/owntracks/seen_ips}" # directory to store per-IP timestamp files
IP_TTL="${IP_TTL:-$(( 30 * 24 * 3600 ))}"                # one month in seconds before an IP is considered new again
WATCH_PATH="${WATCH_PATH:-/owntracks/}"                   # path prefix to watch for logins

# Validate required config
if [[ "$SMTP2GO_KEY" == api-xxx* ]]; then
    echo "ERROR: SMTP2GO_KEY is not set. Edit the script or set the SMTP2GO_KEY environment variable." >&2
    exit 1
fi
if [[ "$FROM_EMAIL" == *example.com || "$TO_EMAIL" == *example.com ]]; then
    echo "ERROR: FROM_EMAIL and TO_EMAIL must be set. Edit the script or set them as environment variables." >&2
    exit 1
fi

# Create the seen IPs directory if it doesn't exist
mkdir -p "$SEEN_IPS_DIR"

# Fetch Cloudflare IP ranges at startup from the official source.
# Stored as an array of CIDRs to check against each log line.
# If the fetch fails, the script continues without Cloudflare filtering and logs a warning.
CF_RANGES=()
while IFS= read -r cidr; do
    [[ -n "$cidr" ]] && CF_RANGES+=("$cidr")
done < <(curl -sf https://www.cloudflare.com/ips-v4 && curl -sf https://www.cloudflare.com/ips-v6)

if [[ "${#CF_RANGES[@]}" -eq 0 ]]; then
    echo "WARNING: Failed to fetch Cloudflare IP ranges. Cloudflare IPs will not be excluded." >&2
else
    echo "Loaded ${#CF_RANGES[@]} Cloudflare IP ranges."
fi

# Check if an IP falls within any Cloudflare CIDR range.
# Requires ipcalc: sudo apt install ipcalc
is_cloudflare_ip() {
    local ip="$1"
    for cidr in "${CF_RANGES[@]}"; do
        if ipcalc -n "$ip" "$cidr" 2>/dev/null | grep -q "^NETWORK="; then
            local net_of_ip net_of_cidr
            net_of_ip=$(ipcalc -n "$ip" "$cidr" 2>/dev/null | grep "^NETWORK=" | cut -d= -f2)
            net_of_cidr=$(ipcalc -n "$cidr" 2>/dev/null | grep "^NETWORK=" | cut -d= -f2)
            [[ "$net_of_ip" == "$net_of_cidr" ]] && return 0
        fi
    done
    return 1
}

echo "Watching $NGINX_LOG for logins to $WATCH_PATH ..."

# Follow the log from the current end, blocking until new lines appear.
# -F (vs -f) handles log rotation automatically.
tail -F -n 0 "$NGINX_LOG" | while read -r line; do

    # Extract fields from nginx combined log format:
    # $1=ip  $3=user  $7=path  $9=status
    status=$(echo "$line" | awk '{print $9}')
    user=$(echo "$line" | awk '{print $3}')
    ip=$(echo "$line" | awk '{print $1}')
    path=$(echo "$line" | awk '{print $7}')

    # Skip anything that isn't a successful response
    [[ "$status" != "200" ]] && continue

    # Skip requests not to the owntracks frontend
    [[ "$path" != ${WATCH_PATH}* && "$path" != "$WATCH_PATH" ]] && continue

    # Skip unauthenticated requests (nginx logs '-' when no basic auth user)
    [[ "$user" == "-" ]] && continue

    # Skip Cloudflare IPs — these are proxy hops, not real users
    is_cloudflare_ip "$ip" && continue

    # Build a per-user/ip file path, e.g. /var/lib/owntracks/seen_ips/admin_1.2.3.4
    # Sanitise the user and ip fields to avoid any path traversal
    safe_user=$(echo "$user" | tr -cd '[:alnum:]_-')
    safe_ip=$(echo "$ip" | tr -cd '[:alnum:]._-')
    IP_FILE="$SEEN_IPS_DIR/${safe_user}_${safe_ip}"

    now=$(date +%s)

    # If the IP file exists and is less than a month old, ignore it
    if [[ -f "$IP_FILE" ]]; then
        last_seen=$(cat "$IP_FILE")
        age=$(( now - last_seen ))
        [[ "$age" -lt "$IP_TTL" ]] && continue
    fi

    # New or expired IP — update the timestamp before sending so a
    # failed curl won't cause a spam loop on the next log line
    echo "$now" > "$IP_FILE"

    # POST to smtp2go REST API to send the notification email
    curl -s -X POST https://api.smtp2go.com/v3/email/send \
        -H "Content-Type: application/json" \
        -d "{
            \"api_key\": \"$SMTP2GO_KEY\",
            \"sender\": \"$FROM_EMAIL\",
            \"to\": [\"$TO_EMAIL\"],
            \"subject\": \"OwnTracks login: $user from $ip\",
            \"text_body\": \"Login detected\nUser: $user\nIP: $ip\"
        }"

    echo "Email sent for $user from $ip"
done
