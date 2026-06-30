# Power And Thermals

Old iPhones can run camera + hardware H.264 + Wi-Fi continuously, but heat is the limiting factor.

## Recommended Baseline

- `1280x720`
- `10-15fps`
- `1.0-1.5Mbps`
- No audio
- No preview layer
- Screen brightness at `0`
- Plugged into power
- Case removed

## If It Gets Warm

Lower frame rate first:

```bash
camera-mode optimize
camera-mode off
camera-mode on
```

If it still runs warm, lower bitrate more before trying 1080p.

## Mounting

- Do not mount flat against fabric, foam, or insulation.
- Leave air behind the phone.
- Avoid direct sunlight.
- Use a slower charger if the phone and charging brick both get hot.

## Monitoring

The status endpoint reports battery and thermal state:

```bash
curl http://$DEVICE_IP:8080/status
```

Watch:

- `thermalState`
- `batteryState`
- `batteryLevel`
- `encodedFrames`
- `motionDetected`

If `thermalState` reaches `serious` or `critical`, lower stream settings or stop camera mode until it cools.

If iOS reports `critical`, the app pauses the encoder and restarts it after the device cools back to `nominal` or `fair`.
