# owntracks-login-notify

A lightweight Debian/Linux daemon that watches your nginx access log and sends an email via [smtp2go](https://www.smtp2go.com) whenever a new IP address authenticates to your [OwnTracks](https://owntracks.org) frontend.

## How it works

- Tails the nginx access log in real time using `tail -F`
- Filters for authenticated `200` responses to your OwnTracks path
- Excludes Cloudflare proxy IPs (fetched fresh from the official Cloudflare API on each service start, cached locally, matched via [`grepcidr`](https://www.pc-tools.net/unix/grepcidr/) — IPv4 + IPv6)
- Tracks seen IP addresses in `/var/lib/owntracks/seen_ips/` — one file per `user_ip` pair
- Fires an email the first time an IP is seen, then ignores it for 30 days
- Runs as a systemd service, starts automatically on boot

## Requirements

- Debian/Ubuntu Linux
- nginx with HTTP Basic Auth
- `curl`, `awk`, `tail`, `grepcidr` (`sudo apt install curl gawk coreutils grepcidr`)
- An [smtp2go](https://www.smtp2go.com) account with an API key and verified sender address

## Installation

```bash
git clone https://github.com/Kinsman4249/owntracks-login-notify.git
cd owntracks-login-notify
sudo bash install.sh
```

The installer will prompt for your smtp2go API key, sender address, and recipient address (plus optional values like the nginx log path and watch path). No need to edit any files by hand.

Verify it is running:

```bash
sudo systemctl status owntracks-login-notify
```

## Upgrading

Pull the latest changes and re-run the installer — it's idempotent and upgrade-aware:

```bash
git pull
sudo bash install.sh
```

On an existing install, it will:

- Detect the previous version
- Load the current config from `/etc/default/owntracks-login-notify` (or migrate inline config from the old script if you're coming from v1.0.0)
- Prompt only for values that are missing or still placeholders, showing the current value as the default — press ENTER to keep it
- Stop the service, swap the script + unit file, restart, and verify

### Non-interactive / unattended installs

Pass `--yes` (or `-y` / `--non-interactive`) and supply any missing values via environment variables:

```bash
sudo SMTP2GO_KEY="api-..." FROM_EMAIL="alerts@example.com" TO_EMAIL="me@example.com" \
    bash install.sh --yes
```

`sudo -E` preserves all env vars if you prefer that pattern.

## Configuration

Config lives at `/etc/default/owntracks-login-notify` (chmod 600, root-owned — contains the API key). The systemd unit loads it via `EnvironmentFile=`. Edit it directly to change a value, then restart the service:

```bash
sudo $EDITOR /etc/default/owntracks-login-notify
sudo systemctl restart owntracks-login-notify
```

| Variable | Default | Description |
|---|---|---|
| `SMTP2GO_KEY` | *(required)* | smtp2go API key |
| `FROM_EMAIL` | *(required)* | Verified sender address |
| `TO_EMAIL` | *(required)* | Notification recipient address |
| `NGINX_LOG` | `/var/log/nginx/access.log` | Path to the nginx access log |
| `WATCH_PATH` | `/owntracks/` | URL path prefix to monitor |
| `IP_TTL` | `2592000` (30 days) | Seconds before an IP is considered new again |
| `SEEN_IPS_DIR` | `/var/lib/owntracks/seen_ips` | Directory for IP tracking files |
| `CF_RANGES_FILE` | `/var/lib/owntracks/cf_ranges.txt` | Cached Cloudflare CIDR list (refreshed on each service start) |

See `owntracks-login-notify.env.example` for a fully commented template.

## Uninstallation

```bash
sudo bash uninstall.sh
```

You'll be asked whether to also remove the config file and seen-IP records. To skip the prompt and keep them, pass `--yes`. To delete everything in one go, pass `--purge`:

```bash
sudo bash uninstall.sh --purge
```

## Maintenance

```bash
# View live logs
sudo journalctl -u owntracks-login-notify -f

# Restart after editing /etc/default/owntracks-login-notify
sudo systemctl restart owntracks-login-notify

# Force re-notification from a specific IP
sudo rm /var/lib/owntracks/seen_ips/admin_1.2.3.4
```

## Notes

- This relies on nginx's HTTP Basic Auth logging the username in the `$remote_user` field (standard in the `combined` log format). If your nginx uses a custom log format, verify `$remote_user` is included.
- **If you're behind Cloudflare**, nginx will log Cloudflare's edge IP as the remote address — not the real visitor IP. The CF filter will correctly classify every request as Cloudflare and you'll never get an alert. Configure nginx's `real_ip` module with `set_real_ip_from` (Cloudflare's ranges) and `real_ip_header CF-Connecting-IP` so the actual visitor IP ends up in the log. See [Cloudflare's docs](https://developers.cloudflare.com/support/troubleshooting/restoring-visitor-ips/restoring-original-visitor-ips/) for the up-to-date snippet.
- On each service start the daemon runs a self-test (`1.1.1.1` should classify as Cloudflare). If the test fails the service exits loudly rather than silently sending an email for every authenticated request.

## License

Apache 2.0 — see [LICENSE](LICENSE).
