#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Contributors to owntracks-login-notify
#
# uninstall.sh — stops and removes owntracks-login-notify.
# Must be run as root (or with sudo).

set -e

SCRIPT_DST="/usr/local/bin/owntracks-login-notify.sh"
SERVICE_DST="/etc/systemd/system/owntracks-login-notify.service"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run as root or with sudo." >&2
    exit 1
fi

echo "Stopping and disabling service ..."
systemctl stop owntracks-login-notify 2>/dev/null || true
systemctl disable owntracks-login-notify 2>/dev/null || true

echo "Removing service unit ..."
rm -f "$SERVICE_DST"

echo "Removing script ..."
rm -f "$SCRIPT_DST"

echo "Reloading systemd ..."
systemctl daemon-reload

echo ""
echo "Uninstall complete."
echo "Note: Seen IP records in /var/lib/owntracks/seen_ips have been left in place."
echo "Remove them manually with: sudo rm -rf /var/lib/owntracks/seen_ips"
