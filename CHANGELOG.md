# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Kinsman4249/owntracks-login-notify/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Kinsman4249/owntracks-login-notify/releases/tag/v1.0.0
