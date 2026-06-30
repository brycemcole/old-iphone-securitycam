# Changelog

## 0.3.0

- Adds locked-screen resilience with `UIBackgroundModes=audio`, silent playback keepalive, a SecurityCam-only foreground/background substrate hook, capture interruption tracking, and status fields for `captureRunning` and `lastCaptureEvent`.
- Adds daemon health checks against the local status endpoint so a wedged app can be restarted even if the process still exists.
- Adds thermal critical pause/recovery guardrail.
- Adds `camera-mode optimize`, `camera-mode balanced`, and `camera-mode services`.
- Adds overnight validation monitor and release checklist for live view, HKSV, Wi-Fi recovery, thermals, charging, and support matrix.

## 0.2.0

- Adds Bonjour/mDNS advertising for HTTP, RTSP, and a dedicated `_oldiphonecam._tcp` service.
- Adds network-change monitoring that refreshes Bonjour when the Wi-Fi address changes.
- Updates the Scrypted helper to discover the phone over Bonjour when no host is configured.
- Adds migration hooks from the original private test package id.

## 0.1.0

- Initial public package.
- Adds black-screen camera app with RTSP H.264, HTTP status, snapshots, and MJPEG snapshot stream.
- Adds `camera-mode` CLI.
- Adds launch daemon persistence.
- Adds SpringBoard hardware-button escape combo.
- Adds Scrypted/HomeKit helper with HKSV-oriented MotionSensor and Rebroadcast/Prebuffer setup.
