# Changelog

## 1.0.0 — Initial public source release (2026-11-14)

- First GitHub-ready source distribution, based on internally validated Build 31.9.5.2.
- Native Intel macOS menu-bar SSH-to-TigerVNC connection manager, multiple server profiles and SSH-key management.
- Core Animation connection-status indicators (1 second per rotation).
- Optional removal of used keys from `ssh-agent` on explicit Quit, only when actually registered (default OFF).
- Public-facing documentation, consistent 1.0.0 metadata, release build scripts and repository hygiene.
- Source licensing: `GPL-2.0-or-later` (subject to verification of all contributor rights and any incorporated third-party material).

Known validation gaps: failure-injection Retry Cleanup testing, sleep/wake, extended runtime and other R01–R08 stress tests.

The pre-publication internal build series `31.x` is retained separately in development archives, not in this public release tree.
