import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import '../identity.dart';

/// A phone that has paired with this PC.
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.tokenHash,
    required this.pairedAt,
    this.lastSeen,
  });

  final String id;
  final String name;

  /// SHA-256 of the device token. The token itself is never stored on the PC.
  final String tokenHash;
  final DateTime pairedAt;
  DateTime? lastSeen;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'tokenHash': tokenHash,
    'pairedAt': pairedAt.toIso8601String(),
    'lastSeen': lastSeen?.toIso8601String(),
  };

  factory PairedDevice.fromJson(Map<String, Object?> j) => PairedDevice(
    id: j['id'] as String,
    name: j['name'] as String,
    tokenHash: j['tokenHash'] as String,
    pairedAt: DateTime.parse(j['pairedAt'] as String),
    lastSeen: j['lastSeen'] == null
        ? null
        : DateTime.parse(j['lastSeen'] as String),
  );
}

String hashToken(String token) => sha256.convert(utf8.encode(token)).toString();

/// Paired devices, saved in `devices.json`.
class DeviceStore {
  DeviceStore._(this._file, this._devices);

  final File _file;
  final List<PairedDevice> _devices;
  final _changes = StreamController<void>.broadcast();
  Timer? _saveTimer;

  /// Fires whenever a device is added, revoked or seen.
  Stream<void> get changes => _changes.stream;
  List<PairedDevice> get devices => List.unmodifiable(_devices);

  static Future<DeviceStore> load(File file) async {
    final devices = <PairedDevice>[];
    if (await file.exists()) {
      final json = jsonDecode(await file.readAsString()) as List;
      for (final d in json) {
        devices.add(PairedDevice.fromJson((d as Map).cast<String, Object?>()));
      }
    }
    return DeviceStore._(file, devices);
  }

  /// Creates a device and returns its token (shown to the phone once).
  Future<(PairedDevice, String)> add(String name) async {
    final token = randomToken(32);
    final device = PairedDevice(
      id: randomToken(9),
      name: name.trim().isEmpty ? 'Phone' : name.trim(),
      tokenHash: hashToken(token),
      pairedAt: DateTime.now(),
    );
    _devices.add(device);
    await _save();
    return (device, token);
  }

  Future<void> revoke(String deviceId) async {
    _devices.removeWhere((d) => d.id == deviceId);
    await _save();
  }

  /// The device owning [token], or null.
  PairedDevice? findByToken(String token) {
    final hash = hashToken(token);
    for (final d in _devices) {
      if (constantTimeEquals(d.tokenHash, hash)) return d;
    }
    return null;
  }

  /// Records that [device] made a request. Saved at most every few seconds.
  void touch(PairedDevice device) {
    device.lastSeen = DateTime.now();
    _saveTimer ??= Timer(const Duration(seconds: 5), () {
      _saveTimer = null;
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert([for (final d in _devices) d.toJson()]),
      flush: true,
    );
    await tmp.rename(_file.path);
    _changes.add(null);
  }
}

/// A short window in which one phone may pair, opened from the PC's UI.
class PairingWindow {
  PairingWindow({this.lifetime = const Duration(minutes: 5)})
    : code = randomToken(16),
      _expires = DateTime.now().add(lifetime);

  static const maxFailedAttempts = 5;

  final Duration lifetime;
  final String code;
  final DateTime _expires;
  int _failures = 0;
  bool _closed = false;

  DateTime get expires => _expires;
  bool get isOpen => !_closed && DateTime.now().isBefore(_expires);

  void close() => _closed = true;

  /// Checks a code from a phone. A correct code closes the window (single
  /// use); too many wrong codes close it too, so guessing is pointless.
  bool tryConsume(String candidate) {
    if (!isOpen) return false;
    if (constantTimeEquals(candidate, code)) {
      _closed = true;
      return true;
    }
    if (++_failures >= maxFailedAttempts) _closed = true;
    return false;
  }
}
