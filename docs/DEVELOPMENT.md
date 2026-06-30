# Development

## Build

```bash
scripts/build.sh
```

`scripts/build.sh` searches for Theos in:

- `$THEOS`
- `./theos`
- `~/theos`
- `/opt/theos`
- `/tmp/theos`

## Deploy

```bash
cp .env.example .env
$EDITOR .env
scripts/deploy.sh
scripts/start-camera-mode.sh
```

## Package Contents

- `SecurityCam.app`: black-screen camera app and RTSP/HTTP server.
- `securitycamd`: launch daemon process.
- `camera-mode`: CLI control tool.
- `SecurityCamEscape.dylib`: SpringBoard escape-combo tweak.
- `com.github.bryce.securitycamd.plist`: launch daemon definition.

The app advertises `_oldiphonecam._tcp`, `_rtsp._tcp`, and `_http._tcp` over Bonjour so Scrypted can rediscover it after DHCP/IP changes.

## Release Checklist

```bash
scripts/release-check.sh
scripts/build.sh
```

Before publishing:

- Do not commit `.env`.
- Do not commit `.theos/`.
- Do not commit `packages/`.
- Do not commit `artifacts/`; they may contain private camera frames.
- Verify the generated `.deb` installs on a test phone.
