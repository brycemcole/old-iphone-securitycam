# Validation Checklist

Use this before tagging a release or trusting the phone overnight. The goal is to prove the full path:

```text
iPhone camera -> RTSP/HTTP -> Scrypted -> HomeKit live view -> HKSV recordings
```

## Does the camera keep streaming with the screen truly off?

Pass criteria:

- Lock the iPhone with the hardware button.
- Or run `camera-mode lock` if the device exposes the SpringBoardServices lock call.
- Leave it locked for at least 10 minutes.
- `captureRunning` remains `true`.
- `encodedFrames` continues increasing.
- `ffprobe -rtsp_transport tcp -i rtsp://PHONE_HOST:8554/live` still succeeds.

Relevant implementation:

- The app has no preview layer.
- The app declares the `audio` background mode and runs a silent playback keepalive.
- The substrate tweak injects into SecurityCam and reports the app as active/not backgrounded while camera mode is enabled.
- The daemon restarts the app if the local `/status` endpoint stops answering.
- The status endpoint reports `captureRunning` and `lastCaptureEvent`.

Practical limitation:

- If the app is fully stopped while the phone is already locked, iOS may block the foreground launch until the phone is unlocked once. Start camera mode from an unlocked phone, confirm `/status`, then lock it for the true-lock test.

Confirmed result:

- Passed a 6-minute physical-lock validation on iPhone SE `iPhone8,4`, iOS `13.1.2`, with package `0.3.0-3+debug`. See [VALIDATION_RESULTS.md](VALIDATION_RESULTS.md).

## Does Apple Home live view work reliably?

Pass criteria:

- Scrypted can probe the phone RTSP stream.
- Scrypted Rebroadcast/Prebuffer is enabled.
- The HomeKit camera is paired as a standalone accessory.
- Apple Home opens live view repeatedly without spinning forever.

Suggested check:

```bash
node scripts/scrypted-iphone-se-setup.js --apply
```

Then open Apple Home live view 10 times from the same Wi-Fi network. If it spins, check direct RTSP first, then the Scrypted rebroadcast stream.

## Do recordings show up in HomeKit Secure Video?

Pass criteria:

- In Apple Home, set the camera to `Stream & Allow Recording`.
- Use `Any Motion` for the first test.
- Trigger visible motion in front of the phone.
- A recording appears in the Home timeline.

Scrypted must provide the motion event. This project exposes luminance-based motion telemetry through the Scrypted script camera so HomeKit Secure Video has a motion trigger.

## Does it survive overnight?

Pass criteria:

- Run the monitor for 8 hours.
- Status checks stay mostly green.
- RTSP probes stay mostly green.
- `encodedFrames` keeps increasing between samples.
- `thermalState` does not sit at `serious` or `critical`.
- The final sample still reports `captureRunning: true`.

Command:

```bash
DEVICE_IP=192.168.1.50 scripts/overnight-monitor.js
```

The monitor writes JSONL under `artifacts/`.

## How hot does the iPhone get?

Pass criteria:

- Preferred: `thermalState` stays `nominal` or `fair`.
- Acceptable for short periods: `serious`, with bitrate/fps reduced.
- Fail: `critical`, repeated thermal pauses, hot casing, or charging heat that keeps climbing.

The app pauses the encoder if iOS reports `critical` thermal state and restarts after it cools back to `nominal` or `fair`.

## Does Wi-Fi reconnect after a drop?

Pass criteria:

- Disable/re-enable Wi-Fi or roam between access points.
- Bonjour advertises `_oldiphonecam._tcp` again.
- Scrypted uses the `.local` hostname or reruns discovery successfully.
- Direct RTSP works again without editing static IP settings.

Relevant implementation:

- The phone advertises `_oldiphonecam._tcp`, `_rtsp._tcp`, and `_http._tcp`.
- The app watches `en0` address changes and refreshes Bonjour.
- The Scrypted helper discovers the phone over Bonjour when no static host is provided.

## Does charging stay sane, or does the battery swell or heat?

Pass criteria:

- Battery state remains stable while plugged in.
- `thermalState` stays `nominal` or `fair` during the overnight monitor.
- The phone is out of a case, has airflow, and is not in direct sunlight.
- There is no bulging screen, swelling, chemical smell, or unusual heat.

Software cannot guarantee battery health on an old phone. If the device gets hot while charging, lower the stream profile, use a lower-wattage charger, improve airflow, or stop camera mode.

## What services are disabled, and what is left alive?

Run:

```bash
camera-mode services
```

Disabled or inhibited by this project:

- live preview rendering
- audio capture and audio streaming
- late video frame backlog
- app background fetch
- screen brightness while camera mode is active

Left alive intentionally:

- camera and mediaserver services
- Wi-Fi, mDNS/Bonjour, and local networking
- SpringBoard/backboardd for lock state and button escape
- power management and thermal management
- Scrypted/HomeKit on the server side

This project does not unload random Apple daemons. That kind of power saving is jailbreak-, device-, and iOS-version-specific and can break the camera, Wi-Fi, HomeKit discovery, or the hardware-button escape path.

## What iOS version, jailbreak, and device does this work on?

Supported target:

- rootful jailbreak layout
- iOS 13 or newer
- arm64 iPhone with AVFoundation and VideoToolbox hardware H.264
- tested development target: first-generation iPhone SE, `iPhone8,4`, iOS `13.1.2` build `17A860`, MobileSubstrate `0.9.7113`, Cydia `1.1.38`

Rootless packaging is not implemented yet. Add confirmed device/iOS/jailbreak combinations to the release notes after running this checklist.
