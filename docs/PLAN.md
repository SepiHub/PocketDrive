# PocketDrive build plan

## Architecture

### PC app (`pc_app`)
- Server runs in the Windows app on a fixed port (8787), HTTPS with a self-signed certificate generated on first run.
- Endpoints (all paths relative to the shared folder):
  - `GET  /api/list?path=` – folder listing
  - `GET  /api/file?path=` – download / streaming, supports HTTP `Range`
  - `GET  /api/thumb?path=&size=` – photo/video thumbnail
  - `POST /api/upload?path=` – upload
  - `POST /api/pair` – exchange one-time pairing code for a device token
- Path safety on every request: reject absolute paths, `..`, drive letters, UNC paths and `:` (alternate data streams); resolve symlinks/junctions and require the real path to be inside the shared folder; listings skip entries that resolve outside it.
- Uploads are written to `*.partial` and renamed when complete; never overwrite (auto-rename to `name (2).ext`).
- Thumbnails come from the Windows shell thumbnail provider (same as Explorer), cached in `%LOCALAPPDATA%\PocketDrive\thumbs`.
- Config in `%APPDATA%\PocketDrive`: shared folder, PC id, certificate, hashed device tokens.

### Pairing
- QR code: PC address, port, PC id, one-time pairing code (5 min, single use), certificate SHA-256 fingerprint.
- Phone calls `/api/pair`, receives a random 256-bit device token, stores it in Android secure storage.
- PC stores only `SHA-256(token)`; paired devices are listed in the PC app with a Revoke button.

### Phone app (`phone_app`)
- QR scan (camera permission), secure token storage, pinned HTTPS client.
- Folder browser, photo grid with cached thumbnails, zoomable photo viewer.
- Video playback with seeking through a small loopback relay on the phone (the system video player cannot pin a self-signed certificate).
- Uploads via the Android Photo Picker (no storage permission needed).

### Discovery and tray
- mDNS service `_pcstorage._tcp` with the PC id in the TXT record; the phone matches by PC id, so IP changes are fine. Falls back to the last known address.
- Closing the window hides to the system tray; optional start at login.

### Remote access later
Nothing in auth or the protocol assumes the LAN. The server currently refuses non-private client addresses; remote access can later be added via a VPN such as Tailscale.

## Stages

| # | Stage | Test |
|---|---|---|
| 1 ✅ | PC server + folder picker | Unit tests for traversal/junction escapes; `curl` locally (server bound to localhost until auth exists) |
| 2 | Pairing (QR + token) + HTTPS | Scan from the phone; no/wrong/revoked token is rejected |
| 3 | Phone browsing + thumbnails | Install on the phone, browse, check the grid |
| 4 | Video streaming | Play a large video and seek around |
| 5 | Uploads from the gallery | Upload photos and a large video; check names and sizes |
| 6 | mDNS discovery + system tray | Phone finds the PC after an IP change or restart; tray menu works |
