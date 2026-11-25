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
- Video player with seeking, swipe between videos, zoom, mute, loop, speed and subtitles (built into the video, via FFmpeg on the PC, or `.srt`/`.vtt` files next to it), full screen without the status bar.
- Slideshow of a folder (shuffle, configurable photo time, videos play to the end).
- Upload from the gallery or the Files app (no limit), Gallery-style multi-select to move or delete.
- Hide folders from the app (they stay normal on the PC); show them again from the sort menu.

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

## Installing

Download both files from the [latest release](https://github.com/SepiHub/PocketDrive/releases/latest):

- **PC:** run `PocketDrive-Setup-x.y.z.exe`. It installs for your Windows account only (no admin
  prompt) and can optionally download FFmpeg for built-in subtitle tracks. Windows may warn that
  the installer is unrecognized; choose *More info* > *Run anyway*.
- **Phone:** open `PocketDrive-x.y.z.apk` on your Android phone and allow installing it.

Both apps check GitHub for new versions and update with one tap. Pairings and settings are kept.

## Releasing

```powershell
.	oolselease.ps1            # build the next version into dist\ to test
.	oolselease.ps1 -Publish   # build, tag and publish it as a GitHub release
```

Needs Inno Setup 6 (`winget install JRSoftware.InnoSetup`) and the Android signing key
(`phone_app/android/key.properties`, never committed).

## Building

Requires Flutter (stable) with Windows desktop and Android toolchains. Optional on the PC: [FFmpeg](https://ffmpeg.org) for built-in subtitle tracks (`winget install Gyan.FFmpeg`).

```powershell
cd pc_app;    flutter run -d windows
cd phone_app; flutter run -d <your-phone>
```
