# PocketDrive

Use a folder on your Windows PC as extra storage for your Android phone, over your home Wi-Fi.

## Features

**PC app (Windows, Flutter)**
- Share one folder through a local HTTPS server: list, download, ranged streaming, thumbnails (Windows' own thumbnail engine, photos and videos), upload, new folder, move, delete (to the Recycle Bin).
- Pair phones with a QR code; see and remove paired phones.
- Announces itself on the network (mDNS) so phones find it after an address change.
- Lives in the system tray: closing the window keeps sharing; optional start with Windows.

**Phone app (Android, Flutter)**
- Pair once by scanning the QR code; finds the PC by itself afterwards ("Find my PC" in the menu).
- Browse folders (with file counts), sort by name, date or size, preview grid, full-screen photo viewer with pinch and double-tap zoom, animated GIFs.
- Video player with seeking, swipe between videos, zoom, mute, loop and speed.
- Slideshow of a folder (shuffle, configurable photo time, videos play to the end).
- Upload from the gallery or the Files app (no limit), Gallery-style multi-select to move or delete.

See [docs/PLAN.md](docs/PLAN.md) for the design and how it was built in stages.

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
