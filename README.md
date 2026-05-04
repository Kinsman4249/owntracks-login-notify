# owntracks-login-notify

A lightweight Debian/Linux daemon that watches your nginx access log and sends an email via [smtp2go](https://www.smtp2go.com) whenever a new IP address authenticates to your [OwnTracks](https://owntracks.org) frontend.

## How it works

- Tails the nginx access log in real time using `tail -F`
- Filters for authenticated `200` responses to your OwnTracks path
- Excludes Cloudflare proxy IPs (fetched fresh from the official Cloudflare API at startup)
- Tracks seen IP addresses in `/var/lib/owntracks/seen_ips/` — one file per `user_ip` pair
- Fires an email the first time an IP is seen, then ignores it for 30 days
- Runs as a systemd service, starts automatically on boot

## Requirements

- Debian/Ubuntu Linux
- nginx with HTTP Basic Auth
- `curl` and `ipcalc` (`sudo apt install curl ipcalc`)
- An [smtp2go](https://www.smtp2go.com) account with an API key and verified sender address

## Installation

```bash
git clone https://github.com/Kinsman4249/owntracks-login-notify.git
cd owntracks-login-notify
```

Edit `owntracks-login-notify.sh` and set your credentials:

```bash
SMTP2GO_KEY="api-xxxxxxxxxxxxxxxxxxxx"
FROM_EMAIL="you@example.com"
TO_EMAIL="you@example.com"
```

Then run the installer:

```bash
sudo bash install.sh
```

Verify it is running:

```bash
sudo systemctl status owntracks-login-notify
```

## Configuration

All options can be set by editing the script directly or by passing environment variables via the systemd service unit. See the commented `Environment=` lines in `owntracks-login-notify.service`.

| Variable | Default | Description |
|---|---|---|
| `NGINX_LOG` | `/var/log/nginx/access.log` | Path to the nginx access log |
| `SMTP2GO_KEY` | *(required)* | smtp2go API key |
| `FROM_EMAIL` | *(required)* | Verified sender address |
| `TO_EMAIL` | *(required)* | Notification recipient address |
| `SEEN_IPS_DIR` | `/var/lib/owntracks/seen_ips` | Directory for IP tracking files |
| `IP_TTL` | `2592000` (30 days) | Seconds before an IP is considered new again |
| `WATCH_PATH` | `/owntracks/` | URL path prefix to monitor |

## Uninstallation

```bash
sudo bash uninstall.sh
```

Seen IP records are left in place at `/var/lib/owntracks/seen_ips`. Remove them manually if desired:

```bash
sudo rm -rf /var/lib/owntracks/seen_ips
```

## Maintenance

```bash
# View live logs
sudo journalctl -u owntracks-login-notify -f

# Restart after editing the script
sudo systemctl restart owntracks-login-notify

# Force re-notification from a specific IP
sudo rm /var/lib/owntracks/seen_ips/admin_1.2.3.4
```

## Notes

- This relies on nginx's HTTP Basic Auth logging the username in the `$remote_user` field (standard in the `combined` log format). If your nginx uses a custom log format, verify `$remote_user` is included.
- If you are behind Cloudflare's proxy, nginx will log Cloudflare's IP as the remote address, not the real visitor IP. You will need to configure nginx's `real_ip` module with `$http_cf_connecting_ip` to get accurate IPs in the log.

## License

Apache 2.0 — see [LICENSE](LICENSE).
