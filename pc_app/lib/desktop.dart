import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:window_manager/window_manager.dart' as wm;

/// The tray icon and window behaviour: closing the window only hides it
/// (PocketDrive keeps sharing in the background); the tray icon brings it
/// back, pauses/resumes sharing, or quits.
class DesktopShell {
  DesktopShell({required this.onToggleSharing, required this.onQuit});

  final VoidCallback onToggleSharing;
  final Future<void> Function() onQuit;

  tray.TrayIcon? _icon;
  tray.MenuItem? _sharingItem;
  wm.Window? _window;

  // Kept so the native callbacks stay alive.
  final _items = <tray.MenuItem>[];

  void init() {
    _window = wm.WindowManager.instance.getCurrent();
    _window?.addListener((event) {
      if (event is wm.WindowCloseRequestedEvent) {
        event.request.cancel(); // keep running, just hide
        _window?.hide();
      }
    });

    final icon = tray.TrayIcon.create();
    if (icon == null) return; // no tray available: window-only
    _icon = icon;
    icon.icon = tray.ImageAsset.fromAsset('assets/app_icon.ico');
    icon.setTooltip('PocketDrive');

    final menu = tray.Menu.create()!;
    final open = _item('Open PocketDrive', show);
    final sharing = _item('Pause sharing', onToggleSharing);
    final quit = _item('Quit PocketDrive', () => unawaited(onQuit()));
    _sharingItem = sharing;
    menu
      ..addItem(open)
      ..addItem(sharing)
      ..addSeparator()
      ..addItem(quit);
    icon.setContextMenu(menu);
    icon.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
    icon.addListener((event) {
      if (event is tray.TrayIconClickedEvent ||
          event is tray.TrayIconDoubleClickedEvent) {
        show();
      }
    });
    icon.setVisible(true);
  }

  tray.MenuItem _item(String label, void Function() onClick) {
    final item = tray.MenuItem.createWithLabelAndType(
      label,
      tray.MenuItemType.normal,
    )!;
    item.addListener((event) {
      if (event is tray.MenuItemClickedEvent) onClick();
    });
    _items.add(item);
    return item;
  }

  void show() {
    final w = _window;
    if (w == null) return;
    w.show();
    w.restore();
    w.focus();
  }

  /// Updates the tray tooltip and menu to match the sharing state.
  void updateSharing({required bool sharing}) {
    _sharingItem?.label = sharing ? 'Pause sharing' : 'Resume sharing';
    _icon?.setTooltip(sharing ? 'PocketDrive: sharing' : 'PocketDrive: paused');
  }

  void dispose() {
    _icon?.setVisible(false);
    _icon?.dispose();
  }
}

typedef VoidCallback = void Function();

/// Starting with Windows, via the per-user "Run" registry key. The app then
/// starts with `--hidden`: straight to the tray, no window.
abstract final class StartAtLogin {
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _name = 'PocketDrive';

  static Future<bool> isEnabled() async {
    final r = await Process.run('reg', ['query', _runKey, '/v', _name]);
    return r.exitCode == 0;
  }

  static Future<void> setEnabled(bool on) async {
    if (on) {
      await Process.run('reg', [
        'add', _runKey, '/v', _name, '/t', 'REG_SZ', //
        '/d', '"${Platform.resolvedExecutable}" --hidden', '/f',
      ]);
    } else {
      await Process.run('reg', ['delete', _runKey, '/v', _name, '/f']);
    }
  }
}
