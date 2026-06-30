# Old iPhone SecurityCam

Turn a jailbroken spare iPhone into a local-network security camera that broadcasts H.264 over RTSP and exposes snapshots/status over HTTP.

This project is intended for devices you own and spaces where everyone being recorded has consented. The built-in HTTP/RTSP endpoints do not authenticate clients, so keep the phone on a trusted LAN or VLAN and do not expose it directly to the internet.

## Features

- Black-screen camera app with no live preview layer.
- Rear camera capture with hardware H.264 encoding.
- RTSP stream on port `8554`: `rtsp://PHONE_IP:8554/live`.
- HTTP status and snapshots on port `8080`:
  - `http://PHONE_IP:8080/status`
  - `http://PHONE_IP:8080/snapshot.jpg`
  - `http://PHONE_IP:8080/stream.mjpg`
- Bonjour/mDNS advertising for `_oldiphonecam._tcp`, `_rtsp._tcp`, and `_http._tcp`.
- Network-change monitoring that refreshes Bonjour when the phone's Wi-Fi address changes.
- Silent background keepalive plus daemon health checks for locked-screen operation.
- Thermal guardrail that pauses the encoder if iOS reports a critical thermal state.
- Lightweight luminance-based motion telemetry for Scrypted/HomeKit Secure Video.
- Launch daemon that restores camera mode after boot/respring when enabled.
- `camera-mode` CLI for enable/disable/status/tuning.
- SpringBoard escape combo: `Volume Up, Volume Down, Volume Up` or `Volume Down, Volume Up, Volume Down` within 2.5 seconds.
- Scrypted helper that creates a script-backed camera, enables Rebroadcast/Prebuffer, and publishes to HomeKit as a standalone accessory.

## Requirements

- Jailbroken iPhone, rootful layout, iOS 13+.
- Theos with an iOS SDK available.
- `sshpass` on the development machine for the helper deploy scripts.
- `ffprobe` for stream verification.
- Optional: Scrypted with HomeKit, Rebroadcast/Prebuffer, Snapshot, and WebRTC plugins.

Rootless jailbreak support is not packaged yet.

Current tested device: first-generation iPhone SE, `iPhone8,4`, iOS `13.1.2`, MobileSubstrate rootful jailbreak.

## Quick Start

```bash
cp .env.example .env
$EDITOR .env
scripts/build.sh
scripts/deploy.sh
scripts/start-camera-mode.sh
```

The `.env` file should at least set:

```bash
DEVICE_IP=192.168.1.50
DEVICE_USER=root
DEVICE_PASS=alpine
```

Verify from your computer:

```bash
curl http://$DEVICE_IP:8080/status
curl -o snapshot.jpg http://$DEVICE_IP:8080/snapshot.jpg
ffprobe -rtsp_transport tcp -i rtsp://$DEVICE_IP:8554/live
```

## Device Control

```bash
camera-mode on
camera-mode off
camera-mode off --respring
camera-mode lock
camera-mode status
camera-mode optimize
camera-mode balanced
camera-mode services
camera-mode set DesiredFPS 10
camera-mode set DesiredBitrate 1000000
camera-mode set DesiredWidth 1280
camera-mode set DesiredHeight 720
```

Default stream profile is `1280x720`, `15fps`, `1.5Mbps`. `camera-mode optimize` switches to the cooler `1280x720`, `10fps`, `1.0Mbps` profile.

## Scrypted And HomeKit

After the phone stream is live:

```bash
DEVICE_IP=192.168.1.50 node scripts/scrypted-iphone-se-setup.js --apply
```

If `DEVICE_IP` is omitted, the helper tries to discover the phone over Bonjour and will prefer the advertised `.local` hostname for Scrypted. That makes the Scrypted/HomeKit path more tolerant of IP changes.

The helper creates/updates `iPhone SE SecurityCam`, attaches HomeKit and Rebroadcast/Prebuffer mixins, enables prebuffering for the RTSP stream, sets HomeKit standalone accessory mode, and prints the HomeKit pairing code.

For details, read [docs/SCRYPTED_HOMEKIT.md](docs/SCRYPTED_HOMEKIT.md).

Before trusting Apple Home/HKSV, run through [docs/VALIDATION.md](docs/VALIDATION.md).

## Thermal Notes

Start with `720p/15fps`. If the device gets warm, use:

```bash
camera-mode set DesiredFPS 10
camera-mode set DesiredBitrate 1000000
camera-mode off
camera-mode on
```

Keep the phone plugged in, out of a case, and mounted with airflow. More notes are in [docs/THERMALS.md](docs/THERMALS.md).

For overnight checks:

```bash
DEVICE_IP=192.168.1.50 scripts/overnight-monitor.js
```

## Security Notes

- Change the default `root` and `mobile` passwords on the jailbroken phone.
- Keep RTSP/HTTP restricted to a trusted local network.
- Prefer Scrypted/HomeKit for remote access instead of port forwarding the phone.
- Do not use this for covert recording.

## Package

- Debian package id: `com.github.bryce.securitycam`
- App bundle id: `com.github.bryce.securitycam`
- Launch daemon: `com.github.bryce.securitycamd`
- Preference file: `/var/mobile/Library/Preferences/com.github.bryce.securitycam.mode.plist`
- Bonjour service type: `_oldiphonecam._tcp`
