# owntracks-login-notify

A lightweight Debian/Linux daemon that watches your nginx access log and sends an email via [smtp2go](https://www.smtp2go.com) whenever a new IP address authenticates to your [OwnTracks](https://owntracks.org) frontend.

## Behind Cloudflare? Use the Worker instead — it gives more info

If your OwnTracks frontend is proxied through Cloudflare (orange-cloud DNS), use the companion project **[OwnTracks-Security-Notifications-Cloudflare](https://github.com/Kinsman4249/OwnTracks-Security-Notifications-Cloudflare)** — it runs at the Cloudflare edge as a Worker and gives you richer alerts than this daemon can produce from log lines alone:

- Detects **failed** login attempts (401), not just successful ones
- **Geolocates** each IP using Cloudflare's `request.cf` data (country, region, city, ASN) — no external geo API needed
- Sends a separate, higher-priority alert when a successful login comes from **outside your home region**
- Per-scenario cooldowns (1 day for outside-region, 30 days for normal/failed) tracked in Cloudflare KV
- Pass-through — never blocks or modifies your traffic
- No server-side setup, nginx `real_ip` config, or smtp2go on your origin

Use this `owntracks-login-notify` daemon when you're **not** behind Cloudflare (or want a server-side backup alongside the Worker).

## How it works

- Tails the nginx access log in real time using `tail -F`
- Filters for authenticated `200` responses to your OwnTracks path
- Excludes Cloudflare proxy IPs with a **two-layer filter** (see below), matched via [`grepcidr`](https://www.pc-tools.net/unix/grepcidr/) — IPv4 + IPv6
- Tracks seen IP addresses in `/var/lib/owntracks/seen_ips/` — one file per `user_ip` pair
- Fires an email the first time an IP is seen, then ignores it for 30 days
- Runs as a systemd service, starts automatically on boot

### Cloudflare filtering (two layers)

Cloudflare's published `ips-v4`/`ips-v6` lists are only their **customer-facing** ranges. Cloudflare's ASN, **AS13335**, announces many more prefixes (WARP, Zero Trust, Spectrum, newer allocations) that aren't in those files — so a CIDR-only filter built from the published lists lets some Cloudflare IPs through. Two layers close that gap; both use `curl` over HTTPS (no extra dependency):

1. **Startup prefix expansion** — on each service start the daemon fetches the published lists **and** every prefix announced by AS13335 (from [RIPEstat](https://stat.ripe.net/)), dedupes them into the cached ranges file, and matches per-line with `grepcidr`. This keeps the hot path fast while covering the full ASN.
2. **Per-IP ASN failsafe** — immediately before an email would be sent (only for a genuinely new IP that already passed the CIDR and 30-day checks), the daemon looks up that IP's ASN over HTTPS and skips the alert if it's Cloudflare's. Because it only runs for would-be notifications, lookups are rare. It **fails open**: a failed or timed-out lookup is treated as non-Cloudflare, so a transient outage never suppresses a real alert.

Both layers are independently toggleable and the target ASN is configurable — see [Configuration](#configuration).

## Requirements

- Debian/Ubuntu Linux
- nginx with HTTP Basic Auth
- `curl`, `awk`, `tail`, `grepcidr` (`sudo apt install curl gawk coreutils grepcidr`)
- `jq` is optional — used to parse ASN/prefix JSON when present; a `grep` fallback is used otherwise (`sudo apt install jq` if you want it)
- Outbound HTTPS to `stat.ripe.net` (both the startup ASN prefix expansion and the per-IP ASN lookups default to RIPEstat); endpoints are configurable
- An [smtp2go](https://www.smtp2go.com) account with an API key and verified sender address

## Installation

```bash
git clone https://github.com/Kinsman4249/owntracks-login-notify.git
cd owntracks-login-notify
sudo bash install.sh
```

The installer will prompt for your smtp2go API key, sender address, and recipient address (plus optional values like the nginx log path and watch path). No need to edit any files by hand.

It finishes by printing the installed version and a **post-install diagnostics** summary that smoke-tests everything the daemon depends on — nginx log readability, the Cloudflare list fetch, RIPEstat (Layer 1), the ASN lookup endpoint (Layer 2), the smtp2go API **including your API key** (validated without sending a test email), and state-directory writability. Any `FAIL` line comes with pointers on what to look at first; diagnostics never abort the install.

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
| `CF_ASN` | `13335` | Cloudflare's autonomous system number (used by both filter layers) |
| `ASN_PREFIX_EXPANSION` | `1` | Layer 1: merge AS`CF_ASN` announced prefixes into the ranges file at startup (`0` to disable) |
| `ASN_FAILSAFE` | `1` | Layer 2: per-IP ASN lookup just before sending (`0` to disable) |
| `ASN_LOOKUP_TIMEOUT` | `3` | Seconds per per-IP ASN lookup |
| `ASN_LOOKUP_URL` | `https://stat.ripe.net/data/network-info/data.json?resource=` | ASN lookup endpoint; the IP is appended. Both RIPEstat (`{"data":{"asns":[..]}}`) and iptoasn (`{"as_number":N}`) response shapes are understood |
| `RIPESTAT_URL` | `https://stat.ripe.net/data/announced-prefixes/data.json?resource=` | RIPEstat base; `AS<CF_ASN>` is appended |

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

# Which version is installed?
grep -m1 '^VERSION=' /usr/local/bin/owntracks-login-notify.sh
# (the running version is also the first startup line in journalctl:
#  "owntracks-login-notify vX.Y.Z starting ...")

# Restart after editing /etc/default/owntracks-login-notify
sudo systemctl restart owntracks-login-notify

# Force re-notification from a specific IP
sudo rm /var/lib/owntracks/seen_ips/admin_1.2.3.4
```

## Notes

- This relies on nginx's HTTP Basic Auth logging the username in the `$remote_user` field (standard in the `combined` log format). If your nginx uses a custom log format, verify `$remote_user` is included.
- **If you're behind Cloudflare**, the simplest answer is to skip this daemon and use the [Cloudflare Worker helper](https://github.com/Kinsman4249/OwnTracks-Security-Notifications-Cloudflare) — it sees the real visitor IP natively and gives you geolocation + failed-login alerts on top. If you want to keep using this daemon behind Cloudflare anyway, nginx will log Cloudflare's edge IP as the remote address — the CF filter will then classify every request as Cloudflare and you'll never get an alert. Fix it by configuring nginx's `real_ip` module with `set_real_ip_from` (Cloudflare's ranges) and `real_ip_header CF-Connecting-IP` so the actual visitor IP ends up in the log. See [Cloudflare's docs](https://developers.cloudflare.com/support/troubleshooting/restoring-visitor-ips/restoring-original-visitor-ips/) for the up-to-date snippet.
- On each service start the daemon runs self-tests: the CIDR check must classify `1.1.1.1` as Cloudflare (hard failure if not — the service exits rather than emailing on every login), and, when `ASN_FAILSAFE=1`, the ASN check is verified against `1.1.1.1` too (this one only warns, since the ASN failsafe fails open by design).
- Still getting Cloudflare notifications after upgrading? Confirm `journalctl -u owntracks-login-notify` shows a non-zero AS13335 prefix count at startup (Layer 1 reached RIPEstat) and `ASN failsafe self-test passed` (Layer 2 reached the lookup service). If your host blocks outbound HTTPS to `stat.ripe.net`, point `RIPESTAT_URL` / `ASN_LOOKUP_URL` at reachable equivalents. Also make sure the service was actually **restarted** after the upgrade — a long-running old process keeps filtering with the old logic (`sudo systemctl restart owntracks-login-notify`).
- Versions ≤ 1.2.0 defaulted `ASN_LOOKUP_URL` to `api.iptoasn.com`, which sits behind Cloudflare's WAF and blocks many server IPs — the self-test then warns `could not reach ...iptoasn...` and Layer 2 fails open. Upgrading fixes this (the default is now RIPEstat); custom `ASN_LOOKUP_URL` values you set yourself are preserved.

## License

Apache 2.0 — see [LICENSE](LICENSE).
