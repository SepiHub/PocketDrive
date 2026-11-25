import 'dart:async';

import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen on while anything needs it (a playing video, the
/// slideshow, uploads). Each part holds and releases its own claim, so one
/// finishing never turns the screen-lock back on while another still runs.
abstract final class KeepAwake {
  static final _holders = <Object>{};

  static void hold(Object who) {
    if (_holders.add(who) && _holders.length == 1) {
      unawaited(WakelockPlus.enable());
    }
  }

  static void release(Object who) {
    if (_holders.remove(who) && _holders.isEmpty) {
      unawaited(WakelockPlus.disable());
    }
  }
}
