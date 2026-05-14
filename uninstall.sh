#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Contributors to owntracks-login-notify
#
# uninstall.sh — stops and removes owntracks-login-notify.
# Must be run as root (or with sudo).
#
# Usage: sudo bash uninstall.sh [--yes] [--purge]
#
#   --yes / -y   Skip the "remove config/state" prompt and KEEP them.
#   --purge      Also remove /etc/default/owntracks-login-notify, the
#                cached CF ranges file, and the seen-IP records.

set -e

SCRIPT_DST="/usr/local/bin/owntracks-login-notify.sh"
SERVICE_DST="/etc/systemd/system/owntracks-login-notify.service"
CONFIG_DST="/etc/default/owntracks-login-notify"
SEEN_IPS_DIR="/var/lib/owntracks/seen_ips"
CF_RANGES_FILE="/var/lib/owntracks/cf_ranges.txt"

ASSUME_YES=0
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)        ASSUME_YES=1 ;;
        --purge)         PURGE=1 ;;
        --help|-h)
            sed -n '2,13p' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

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

purge() {
    rm -f "$CONFIG_DST"
    rm -f "$CF_RANGES_FILE"
    rm -rf "$SEEN_IPS_DIR"
}

if (( PURGE )); then
    echo "Purging config and state ..."
    purge
    echo
    echo "Uninstall complete. Config, cached CF ranges, and seen-IP records removed."
elif (( ASSUME_YES )); then
    echo
    echo "Uninstall complete."
    echo "Config preserved at:  $CONFIG_DST"
    echo "Seen-IP records:      $SEEN_IPS_DIR"
    echo "Re-run with --purge to remove these."
else
    echo
    echo "Uninstall complete."
    echo "Config preserved at:  $CONFIG_DST (contains your smtp2go API key)"
    echo "Seen-IP records:      $SEEN_IPS_DIR"
    read -r -p "Remove these too? [y/N]: " reply
    if [[ "$reply" =~ ^[yY] ]]; then
        purge
        echo "Purged."
    else
        echo "Left in place."
    fi
fi
