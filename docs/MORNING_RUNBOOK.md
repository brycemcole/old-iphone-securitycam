# Operator Runbook

Use this when bringing a phone online from a cold jailbreak/reboot.

## 1. Configure Local Environment

```bash
cp .env.example .env
$EDITOR .env
```

Set at least:

```bash
DEVICE_IP=192.168.1.50
DEVICE_USER=root
DEVICE_PASS=alpine
```

If the phone advertises over Bonjour, Scrypted setup can discover it without `DEVICE_IP`; the deploy scripts still need `DEVICE_IP` for SSH.

## 2. Build And Install

```bash
scripts/build.sh
scripts/deploy.sh
```

If Theos is not found, set `THEOS=/path/to/theos` or install it into one of the paths listed by `scripts/build.sh`.

## 3. Start Camera Mode

```bash
scripts/start-camera-mode.sh
```

Expected endpoints:

```text
rtsp://DEVICE_IP:8554/live
http://DEVICE_IP:8080/status
http://DEVICE_IP:8080/snapshot.jpg
```

## 4. Verify Stream

```bash
curl http://$DEVICE_IP:8080/status
curl -I http://$DEVICE_IP:8080/snapshot.jpg
ffprobe -rtsp_transport tcp -i rtsp://$DEVICE_IP:8554/live
```

The status endpoint should show:

- `enabled: true`
- increasing `encodedFrames`
- `thermalState: nominal` or `fair`
- expected resolution/fps/bitrate under `desired`

## 5. Add Scrypted/HomeKit

```bash
DEVICE_IP=$DEVICE_IP node scripts/scrypted-iphone-se-setup.js --apply
```

After the release package is installed, this can also discover the phone automatically:

```bash
node scripts/scrypted-iphone-se-setup.js --apply
```

Add the standalone HomeKit accessory printed by the helper, then set Apple Home recording options to `Stream & Allow Recording`.

## 6. Escape Camera Mode

Hardware escape while camera mode is enabled:

```text
Volume Up, Volume Down, Volume Up
```

or:

```text
Volume Down, Volume Up, Volume Down
```

Remote escape:

```bash
scripts/stop-camera-mode.sh
```

## 7. Reduce Heat

```bash
ssh root@$DEVICE_IP 'camera-mode set DesiredFPS 10; camera-mode set DesiredBitrate 1000000; camera-mode off; camera-mode on'
```

Keep the phone plugged in, out of a case, and mounted with airflow.
