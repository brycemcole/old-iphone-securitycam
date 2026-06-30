# Scrypted And HomeKit

The recommended HomeKit path is:

```text
iPhone RTSP/HTTP -> Scrypted script camera -> Rebroadcast/Prebuffer -> Scrypted HomeKit -> Apple Home
```

Do not try to make the phone speak HomeKit directly. Scrypted already handles HomeKit pairing, live stream negotiation, HKSV recording sessions, prebuffering, and Home Hub behavior.

## Setup

1. Start camera mode on the phone.
2. Confirm direct endpoints work:

```bash
curl http://$DEVICE_IP:8080/status
curl -I http://$DEVICE_IP:8080/snapshot.jpg
ffprobe -rtsp_transport tcp -i rtsp://$DEVICE_IP:8554/live
```

3. Apply Scrypted setup:

```bash
DEVICE_IP=$DEVICE_IP node scripts/scrypted-iphone-se-setup.js --apply
```

If `DEVICE_IP`, `IPHONE_SECURITYCAM_HOST`, and explicit stream URLs are omitted, the helper browses for `_oldiphonecam._tcp` and uses the discovered `.local` host.

4. In Apple Home, add the standalone accessory printed by the helper.
5. Set recording options to `Stream & Allow Recording`.
6. For first verification, use an `Any Motion` or `All Motion` recording trigger.

## What The Helper Configures

- Creates/updates the `iPhone SE SecurityCam` script device.
- Provides Camera, VideoCamera, and MotionSensor interfaces.
- Uses the phone snapshot endpoint for still images.
- Uses the phone RTSP endpoint for H.264 live video.
- Installs `@scrypted/prebuffer-mixin` if missing.
- Enables Rebroadcast/Prebuffer for `RTSP H.264`.
- Sets `prebuffer:noAudio=true` because the phone stream is video-only.
- Sets HomeKit standalone accessory mode.
- Sets HomeKit RTP sender to `FFmpeg` for stability.
- Uses Bonjour discovery when no static host is provided.

## Pairing Code

The helper prints `homekit:pincode` after `--apply`. If you need to retrieve it again, run:

```bash
DEVICE_IP=$DEVICE_IP node scripts/scrypted-iphone-se-setup.js --skip-stream --apply
```

## Troubleshooting Live View

If Apple Home shows snapshots but live view spins:

- Confirm the direct RTSP stream works with `ffprobe`.
- Confirm Bonjour sees the phone:
  ```bash
  dns-sd -B _oldiphonecam._tcp local.
  ```
- Confirm Scrypted shows the Rebroadcast mixin on the camera.
- Confirm the camera is paired as a standalone accessory, not only through the bridge.
- Use the new standalone camera tile in Apple Home.
- Avoid resetting HomeKit or deleting Scrypted storage until direct stream and mixin state have been checked.

Useful log filter:

```bash
tail -f ~/.scrypted/scrypted.log | rg --line-buffered 'iPhone SE|HomeKit|handleStreamRequest|Camera recording|motion recording|rebroadcast|prebuffer|error'
```
