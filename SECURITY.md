# Security Policy

This project exposes unauthenticated RTSP and HTTP endpoints on the phone.

Use it only on a trusted local network. Do not port-forward the phone to the internet. Use Scrypted, HomeKit, VPN, or another authenticated layer for remote access.

## Minimum Safety Checklist

- Change default jailbreak passwords for `root` and `mobile`.
- Keep the phone on a trusted LAN or camera VLAN.
- Do not record people without consent.
- Do not publish screenshots, snapshots, or logs that reveal private spaces or network details.
- Treat `.env` as private because it may contain device credentials.

## Reporting Issues

Open a GitHub issue for security-relevant bugs that do not expose private data. If a report includes private network details, camera images, or credentials, redact them before posting.
