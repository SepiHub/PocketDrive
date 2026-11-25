import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The phone app's own preferences (not secret; stored in plain app
/// preferences, unlike the pairing).
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static const _slideSecondsKey = 'slideshow_photo_seconds';
  static const _mutedKey = 'video_muted';
  static const _loopKey = 'video_loop';
  static const defaultSlideSeconds = 5;
  static const slideSecondsChoices = [2, 3, 5, 8, 10, 15, 20, 30];

  final SharedPreferences _prefs;

  static Future<AppSettings> load() async =>
      AppSettings._(await SharedPreferences.getInstance());

  /// How long each photo stays on screen in a slideshow.
  int get slideSeconds =>
      _prefs.getInt(_slideSecondsKey) ?? defaultSlideSeconds;

  /// Videos start muted when true; remembered across app restarts.
  bool get videoMuted => _prefs.getBool(_mutedKey) ?? false;

  /// Videos repeat from the start when they end; remembered.
  bool get videoLoop => _prefs.getBool(_loopKey) ?? false;

  Future<void> setVideoLoop(bool loop) async {
    await _prefs.setBool(_loopKey, loop);
    notifyListeners();
  }

  Future<void> setVideoMuted(bool muted) async {
    await _prefs.setBool(_mutedKey, muted);
    notifyListeners();
  }

  Future<void> setSlideSeconds(int seconds) async {
    await _prefs.setInt(_slideSecondsKey, seconds);
    notifyListeners();
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.settings});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (context, _) => ListView(
          children: [
            const ListTile(title: Text('Slideshow'), dense: true),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Time per photo'),
              subtitle: Text(
                '${settings.slideSeconds} seconds. '
                'Videos always play to the end.',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in AppSettings.slideSecondsChoices)
                    ChoiceChip(
                      label: Text('$s s'),
                      selected: settings.slideSeconds == s,
                      onSelected: (_) => settings.setSlideSeconds(s),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
