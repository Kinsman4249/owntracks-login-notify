#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Contributors to owntracks-login-notify
#
# install.sh — installs owntracks-login-notify and registers it as a systemd service.
# Must be run as root (or with sudo).

set -e

SCRIPT_SRC="owntracks-login-notify.sh"
SCRIPT_DST="/usr/local/bin/owntracks-login-notify.sh"
SERVICE_SRC="owntracks-login-notify.service"
SERVICE_DST="/etc/systemd/system/owntracks-login-notify.service"
SEEN_IPS_DIR="/var/lib/owntracks/seen_ips"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root or with sudo." >&2
    exit 1
fi

# Check dependencies
for cmd in curl ipcalc awk tail; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command '$cmd' not found. Install with: sudo apt install $cmd" >&2
        exit 1
    fi
done

echo "Installing script to $SCRIPT_DST ..."
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"

echo "Installing service unit to $SERVICE_DST ..."
cp "$SERVICE_SRC" "$SERVICE_DST"

echo "Creating seen IPs directory at $SEEN_IPS_DIR ..."
mkdir -p "$SEEN_IPS_DIR"

echo "Reloading systemd ..."
systemctl daemon-reload

echo "Enabling and starting service ..."
systemctl enable --now owntracks-login-notify

echo ""
echo "Done. Check status with:"
echo "  sudo systemctl status owntracks-login-notify"
echo ""
echo "NOTE: Edit $SCRIPT_DST to set your SMTP2GO_KEY, FROM_EMAIL, and TO_EMAIL before use."
