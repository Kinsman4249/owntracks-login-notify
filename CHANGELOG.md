# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.1] - 2026-07-08

### Fixed
- **Layer 2 ASN lookups now default to RIPEstat instead of iptoasn.com.** `api.iptoasn.com` sits behind Cloudflare's WAF, which blocks requests from many server/datacenter IPs — on such hosts the ASN failsafe self-test warned `could not reach ...iptoasn...` and Layer 2 permanently failed open. The default `ASN_LOOKUP_URL` is now RIPEstat's network-info API (`https://stat.ripe.net/data/network-info/data.json?resource=`), the same provider Layer 1 already uses. The parser understands both RIPEstat (`{"data":{"asns":[..]}}`) and iptoasn (`{"as_number":N}`) response shapes, so iptoasn-compatible endpoints still work via `ASN_LOOKUP_URL`.
- `install.sh` now writes the ASN failsafe settings (`CF_ASN`, `ASN_PREFIX_EXPANSION`, `ASN_FAILSAFE`, `ASN_LOOKUP_TIMEOUT`, `ASN_LOOKUP_URL`, `RIPESTAT_URL`) into `/etc/default/owntracks-login-notify` and preserves customised values across re-installs (previously a re-install dropped hand-added ASN lines).
- `get_asn()` now normalises non-numeric parser output to empty, guaranteeing fail-open behaviour on malformed responses.

## [1.2.0] - 2026-07-08

### Added
- **Cloudflare ASN (AS13335) failsafe** to stop notifications from Cloudflare IPs that aren't in the published `ips-v4`/`ips-v6` lists. Those lists are only Cloudflare's customer-facing ranges; AS13335 announces many more prefixes (WARP, Zero Trust, Spectrum, newer allocations) that a CIDR-only filter misses. Two layers, both over HTTPS via `curl` (no new dependency):
  - **Layer 1 — startup prefix expansion:** on each service start the daemon fetches every prefix announced by AS`CF_ASN` from RIPEstat and merges it (deduped) into the cached ranges file alongside the published lists, keeping the per-line `grepcidr` match fast.
  - **Layer 2 — per-IP ASN failsafe:** immediately before an email would be sent (only for a new IP that already passed the CIDR and TTL checks), the candidate IP's ASN is looked up over HTTPS and the alert is skipped if it is Cloudflare's. Results are cached per run; lookups use a short timeout and **fail open** so a transient outage never suppresses a real alert.
- New config: `CF_ASN` (13335), `ASN_PREFIX_EXPANSION` (1), `ASN_FAILSAFE` (1), `ASN_LOOKUP_TIMEOUT` (3), `ASN_LOOKUP_URL`, `RIPESTAT_URL`. All documented in the README and `owntracks-login-notify.env.example`.
- ASN self-test at startup (`1.1.1.1` should resolve to AS`CF_ASN`); warns rather than hard-failing, since the failsafe fails open.
- Optional `jq` support for parsing ASN/prefix JSON, with a `grep`/`sed` fallback when `jq` is absent.

### Changed
- The cached Cloudflare ranges file is now deduped and sorted, and its startup log line reports how many AS`CF_ASN` prefixes were merged.

## [1.1.0] - 2026-05-14

### Fixed
- **Cloudflare IP filter was broken.** `is_cloudflare_ip()` invoked `ipcalc -n "$ip" "$cidr"`, which is not a valid invocation of Debian's `ipcalc` (it takes a single CIDR) and the `-n` flag means different things across ipcalc implementations. The check silently failed for nearly every Cloudflare IP, so any deployment proxied through Cloudflare generated an email for every authenticated request. Replaced with a [`grepcidr`](https://www.pc-tools.net/unix/grepcidr/)-based check that handles IPv4 + IPv6 correctly.

### Added
- **Startup self-test:** the service classifies `1.1.1.1` through `is_cloudflare_ip` on boot and exits with a clear error if it does not match. This class of regression can no longer ship silently.
- **CF range cache** at `/var/lib/owntracks/cf_ranges.txt` (configurable via `CF_RANGES_FILE`). Refreshed from the Cloudflare API on each service start; if the API is unreachable, the cached list is reused. If neither source is available the service refuses to start rather than silently disabling CF filtering.
- **`/etc/default/owntracks-login-notify`** holds runtime config (`SMTP2GO_KEY`, `FROM_EMAIL`, `TO_EMAIL`, `NGINX_LOG`, `WATCH_PATH`, `IP_TTL`, `SEEN_IPS_DIR`, `CF_RANGES_FILE`). The systemd unit loads it via `EnvironmentFile=`. Credentials now survive script upgrades. Mode 0600, root-owned.
- **Upgrade-aware `install.sh`:** detects existing installs, loads config from the new `/etc/default` file, or — on v1.0.0 → v1.x upgrades — parses inline config from `/usr/local/bin/owntracks-login-notify.sh` and migrates it. Prompts only for values that are missing or still placeholders, showing the current value as the default. Supports `--yes` / `--non-interactive` and env-var-driven values for unattended runs. Stops the service before file swap, runs `daemon-reload`, restarts, and verifies with `systemctl is-active`.
- **`uninstall.sh --purge` / interactive prompt** for removing the config file, cached CF ranges, and seen-IP records.
- **`owntracks-login-notify.env.example`** documenting the config file format.
- IPv6 support throughout (CF range matching, safe-IP filename sanitisation).

### Changed
- `owntracks-login-notify.sh` no longer holds credential defaults — all config comes from environment variables populated by the systemd `EnvironmentFile=`.
- Service unit `After=` changed from `network.target` to `network-online.target` (+ `Wants=network-online.target`) so the CF range fetch at startup has a working network.

### Documentation
- README now points users behind Cloudflare at the companion [OwnTracks-Security-Notifications-Cloudflare](https://github.com/Kinsman4249/OwnTracks-Security-Notifications-Cloudflare) Worker, which sees the real visitor IP natively and adds geolocation, failed-login alerts, and outside-region alerts on top.

### Removed
- **`ipcalc` dependency.** Replaced by `grepcidr`.

## [1.0.1] - 2026-05-05

### Documentation
- Adopted the post-1.0 security support policy in [SECURITY.md](SECURITY.md): only the newest major release line receives security updates. No code changes.

## [1.0.0] - 2026-05-04

### Added
- nginx access log tailer that watches for authenticated `200` responses to a configurable OwnTracks path
- smtp2go email notification on the first login from a new IP address
- 30-day TTL on seen IPs (per `user_ip` pair) before re-notification
- Cloudflare proxy IP exclusion using the official Cloudflare IP ranges API at startup
- Configurable via environment variables: `NGINX_LOG`, `SMTP2GO_KEY`, `FROM_EMAIL`, `TO_EMAIL`, `SEEN_IPS_DIR`, `IP_TTL`, `WATCH_PATH`
- systemd service unit (`owntracks-login-notify.service`) with auto-restart and boot-time start
- `install.sh` and `uninstall.sh` for one-command setup and teardown
- Path-traversal protection via sanitization of `user` and `ip` fields before constructing seen-IP file paths
- Apache 2.0 license

[Unreleased]: https://github.com/Kinsman4249/owntracks-login-notify/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/Kinsman4249/owntracks-login-notify/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/Kinsman4249/owntracks-login-notify/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Kinsman4249/owntracks-login-notify/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/Kinsman4249/owntracks-login-notify/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/Kinsman4249/owntracks-login-notify/releases/tag/v1.0.0
