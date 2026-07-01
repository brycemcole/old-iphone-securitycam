# Validation Results

This file records confirmed device results for release notes. Do not include private camera frames or local artifact paths in public release notes.

## 2026-06-30: iPhone SE 1st Gen, iOS 13.1.2, MobileSubstrate

Device:

- iPhone SE first generation, `iPhone8,4`
- iOS `13.1.2`, build `17A860`
- Rootful MobileSubstrate `0.9.7113`, Cydia `1.1.38`
- Package tested: `com.github.bryce.securitycam 0.3.0-3+debug`

### Direct Stream

Passed.

- Profile: aggressive
- Stream: H.264 `1280x720` at `10fps`
- Status endpoint: OK
- Snapshot endpoint: OK
- Thermal state during short test: `nominal`

### True-Lock Streaming

Passed short validation after starting camera mode from an unlocked foreground launch, then physically locking the phone.

- Duration: 6 minutes
- Samples: 11
- Status checks: 11/11 OK
- RTSP probes: 11/11 OK
- Initial encoded frames: `304`
- Final encoded frames: `3709`
- Final live status after monitor: `captureRunning=true`, `encodedFrames=4227`
- Frame deltas stayed around `340` per 30-second sample in the `10fps` profile.
- Thermal state stayed `nominal`.
- Last capture event stayed `capture started`.

Prior failure before the SecurityCam-only foreground/background substrate hook:

- Physical lock interrupted capture with `capture interrupted reason=1`.
- Frame count froze at `999`.
- RTSP stopped responding.

### Scrypted Rebroadcast

Passed source-side validation.

- Scrypted helper discovered phone by Bonjour as `Bryces-iPhone-2.local`.
- Scrypted device has HomeKit and Rebroadcast/Prebuffer mixins.
- Rebroadcast RTSP probed as H.264 `1280x720` at `10fps`.

### Apple Home Live View

Pending repeated-open validation in Apple Home.

### HomeKit Secure Video Recording

Pending Home timeline recording validation.

### Overnight

Pending 8-hour monitor.

### Wi-Fi Reconnect

Pending forced Wi-Fi drop/roam test.

### Charging And Battery Heat

Pending longer plugged-in observation.

## 2026-06-30: Frozen Encoder Recovery

Failure observed on package `0.3.0-3+debug`:

- `/status` stayed alive.
- `captureRunning` stayed `true`.
- Snapshot endpoint returned a JPEG.
- `encodedFrames` froze at `9921`.
- Direct RTSP clients hung or reported incomplete stream dimensions.
- Scrypted Rebroadcast/Prebuffer logged `timeout waiting for data` and Apple Home had no live video.

Fix added in package `0.3.1-1+debug`:

- In-app frame watchdog samples encoded frame progress every 20 seconds.
- If encoded frames do not advance for more than 25 seconds, the app restarts the encoder without relying on process death.
- `/status` now reports `lastEncodedFrameAt`, `lastEncoderRestartAt`, `encoderRestartCount`, and `frameWatchdog`.

Recovery validation after installing `0.3.1-1+debug`:

- Direct RTSP probed as H.264 `1280x720` at `10fps`.
- Scrypted rebroadcast RTSP probed as H.264 `1280x720` at `10fps`.
- Two-minute monitor passed: all status and RTSP samples OK.
- Frames advanced from `492` to `1689`.
- Thermal state moved from `nominal` to `fair`.
- Final checked status reported `captureRunning=true`, `encodedFrames=2095`, `encoderRestartCount=0`, and `frameWatchdog.enabled=true`.

## 2026-06-30: Device Dropped Off LAN

Failure observed after prior successful locked-stream and encoder recovery tests:

- `192.168.86.28` stopped answering HTTP, RTSP, and SSH.
- `192.168.86.46` also did not answer.
- Bonjour no longer advertised `_oldiphonecam._tcp`.
- Scrypted logged `getaddrinfo ENOTFOUND Bryces-iPhone-2.local` and repeated prebuffer timeouts.
- LAN scan did not find another SecurityCam HTTP/RTSP/SSH endpoint.
- ARP showed `bryces-iphone.lan (192.168.86.28)` as incomplete.
- Tailscale `iphone181` was offline.

Interpretation:

- This was not the previous frozen-encoder failure. The whole phone disappeared from the local network or rebooted into a state without jailbreak services.

Mitigation prepared in package `0.3.2-1+debug`, pending install and validation once the phone is reachable:

- App starts a no-idle-sleep power assertion while camera mode is active.
- App sends a periodic local-network heartbeat to the presumed gateway.
- `/status` reports `lastNetworkKeepaliveAt` and `networkKeepaliveTarget`.
