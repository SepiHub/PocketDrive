# PocketDrive

Use a folder on your Windows PC as extra storage for your Android phone, over your home Wi-Fi.

- **PC app (Windows, Flutter):** pick one shared folder; a local HTTPS server exposes only that folder (list, download, upload, video streaming with seeking, photo/video thumbnails). Shows a QR code for pairing, advertises itself with mDNS, lives in the system tray.
- **Phone app (Android, Flutter):** scan the QR code once to pair, then find the PC automatically. Browse folders, view photos in a grid, play videos, upload from the gallery.

> Status: in development. See [docs/PLAN.md](docs/PLAN.md) for the design and build stages.

## Security model

- **Pairing:** the QR code holds the PC's address, a one-time pairing code (valid 5 minutes) and the fingerprint of the PC's self-signed TLS certificate. The phone exchanges the code for a random 256-bit device token, stored in Android's secure storage. The PC stores only a hash of the token and can revoke any device.
- **Every request** must carry a valid device token.
- **Encryption:** all traffic is HTTPS. The phone trusts only the certificate whose fingerprint it got from the QR code (certificate pinning).
- **Folder jail:** requested paths are relative to the shared folder only. Absolute paths, `..`, drive letters, UNC paths and alternate data streams are rejected, and every path is resolved through symlinks/junctions and checked to still be inside the shared folder.
- **Local network only** for now. Keys and certificates are generated on the PC at runtime and are never part of this repository.

## Layout

```
pc_app/     Windows app (server, folder picker, pairing QR, tray)
phone_app/  Android app
shared/     Dart package with the protocol shared by both apps
docs/       Design notes
```

## Building

Requires Flutter (stable) with Windows desktop and Android toolchains.

```powershell
cd pc_app;    flutter run -d windows
cd phone_app; flutter run -d <your-phone>
```
