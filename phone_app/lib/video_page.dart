import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';
import 'package:video_player/video_player.dart';

import 'app_settings.dart';
import 'pc_client.dart';
import 'resume_store.dart';
import 'thumbnails.dart';
import 'video_relay.dart';

/// Subtitle files the player understands.
bool isSubtitleFile(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.srt') || n.endsWith('.vtt');
}

/// Subtitle files that belong to [video]: same name, e.g. for `Movie.mp4`
/// `Movie.srt`, `Movie.en.srt` or `Movie.English.vtt`.
List<String> subtitlesFor(String video, List<String> subtitleFiles) {
  final dot = video.lastIndexOf('.');
  final stem = (dot > 0 ? video.substring(0, dot) : video).toLowerCase();
  return [
    for (final s in subtitleFiles)
      if (s.toLowerCase().startsWith('$stem.')) s,
  ]..sort();
}

/// A short label for a subtitle file ("en", "English", or "Default").
String subtitleLabel(String video, String file) {
  final dot = video.lastIndexOf('.');
  final stem = dot > 0 ? video.substring(0, dot) : video;
  final rest = file.substring(stem.length + 1);
  final ext = rest.lastIndexOf('.');
  final label = ext > 0 ? rest.substring(0, ext) : '';
  return label.isEmpty ? 'Default' : label;
}

/// A subtitle choice for a video: a file next to it, or a track inside it.
class SubOption {
  const SubOption({
    required this.id,
    required this.label,
    this.detail,
    this.enabled = true,
  });

  /// `file:<name>` or `track:<index>`.
  final String id;
  final String label;
  final String? detail;
  final bool enabled;
}

const _languages = {
  'eng': 'English',
  'fre': 'French',
  'fra': 'French',
  'ger': 'German',
  'deu': 'German',
  'spa': 'Spanish',
  'ita': 'Italian',
  'por': 'Portuguese',
  'dut': 'Dutch',
  'nld': 'Dutch',
  'swe': 'Swedish',
  'nor': 'Norwegian',
  'nob': 'Norwegian',
  'dan': 'Danish',
  'fin': 'Finnish',
  'pol': 'Polish',
  'rus': 'Russian',
  'ukr': 'Ukrainian',
  'jpn': 'Japanese',
  'chi': 'Chinese',
  'zho': 'Chinese',
  'kor': 'Korean',
  'ara': 'Arabic',
  'tur': 'Turkish',
  'hun': 'Hungarian',
  'cze': 'Czech',
  'ces': 'Czech',
  'gre': 'Greek',
  'ell': 'Greek',
  'heb': 'Hebrew',
  'rum': 'Romanian',
  'ron': 'Romanian',
  'hin': 'Hindi',
  'tha': 'Thai',
  'vie': 'Vietnamese',
  'ind': 'Indonesian',
  'may': 'Malay',
  'msa': 'Malay',
  'bul': 'Bulgarian',
  'hrv': 'Croatian',
  'srp': 'Serbian',
  'slv': 'Slovenian',
  'slo': 'Slovak',
  'slk': 'Slovak',
  'est': 'Estonian',
  'lav': 'Latvian',
  'lit': 'Lithuanian',
  'ice': 'Icelandic',
  'isl': 'Icelandic',
  'cat': 'Catalan',
  'baq': 'Basque',
  'eus': 'Basque',
  'glg': 'Galician',
  'fil': 'Filipino',
  'per': 'Persian',
  'fas': 'Persian',
};

/// "English", "French (Forced)", "Track 3", ...
String embeddedTrackLabel(EmbeddedTrack t) {
  final lang = t.language;
  final name = lang == null || lang == 'und'
      ? 'Track ${t.index + 1}'
      : _languages[lang.toLowerCase()] ?? lang.toUpperCase();
  return t.title == null ? name : '$name (${t.title})';
}

/// The built-in track to show by default: the phone's language first, and
/// full subtitles before "forced"/"signs" ones.
EmbeddedTrack? defaultEmbeddedTrack(List<EmbeddedTrack> tracks, String lang2) {
  final text = tracks.where((t) => t.isText).toList();
  if (text.isEmpty) return null;
  bool mine(EmbeddedTrack t) {
    final l = (t.language ?? '').toLowerCase();
    final name = _languages[l]?.toLowerCase() ?? '';
    return l.startsWith(lang2) || name.startsWith(_lang2Names[lang2] ?? '?');
  }

  bool partial(EmbeddedTrack t) {
    final title = (t.title ?? '').toLowerCase();
    return title.contains('forced') || title.contains('sign');
  }

  return text.where((t) => mine(t) && !partial(t)).firstOrNull ??
      text.where(mine).firstOrNull ??
      text.where((t) => !partial(t)).firstOrNull ??
      text.first;
}

const _lang2Names = {
  'en': 'english',
  'fr': 'french',
  'de': 'german',
  'es': 'spanish',
  'it': 'italian',
  'pt': 'portuguese',
  'nl': 'dutch',
  'sv': 'swedish',
  'no': 'norwegian',
  'nb': 'norwegian',
  'da': 'danish',
  'fi': 'finnish',
  'pl': 'polish',
  'ru': 'russian',
  'ja': 'japanese',
  'zh': 'chinese',
  'ko': 'korean',
  'ar': 'arabic',
  'tr': 'turkish',
};

/// Strips styling left in converted subtitles: `<i>`, `{\an8}`, ...
String plainCaption(String text) => text
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
    .trim();

/// Plays the videos of one folder from the PC, starting at [initialIndex].
/// It streams: playback starts after the first few seconds arrive, and
/// seeking jumps straight to that part of the file (the player asks the PC
/// for just those bytes). Swipe left/right for the next/previous video.
class VideoPage extends StatefulWidget {
  const VideoPage({
    super.key,
    required this.settings,
    required this.client,
    required this.subtitleFiles,
    required this.relay,
    required this.thumbs,
    required this.folder,
    required this.videos,
    required this.initialIndex,
  });

  final AppSettings settings;
  final PcClient client;

  /// `.srt`/`.vtt` files in the folder (matched to videos by name).
  final List<String> subtitleFiles;
  final VideoRelay relay;
  final ThumbnailCache thumbs;
  final String folder;
  final List<RemoteEntry> videos;
  final int initialIndex;

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  /// Players for the current video and its neighbours, loaded ahead so a
  /// swipe shows the real first frame at once (no preview-image flicker).
  final _players = <int, VideoPlayerController>{};
  final _ready = <int>{};
  final _errors = <int, String>{};
  bool _fullscreen = false;
  late int _index = widget.initialIndex;

  /// Which way the last swipe went (+1 next, -1 previous), for the slide.
  int _direction = 0;

  /// The subtitle shown for each video (a [SubOption.id], null = off).
  final _subtitle = <int, String?>{};

  /// Built-in tracks per video, once the PC answered (FFmpeg present?).
  final _embedded = <int, ({bool available, List<EmbeddedTrack> tracks})>{};
  final _subLoading = <int>{};

  RemoteEntry get _entry => widget.videos[_index];

  List<String> _tracks(int i) =>
      subtitlesFor(widget.videos[i].name, widget.subtitleFiles);

  String _inFolder(String name) =>
      widget.folder.isEmpty ? name : '${widget.folder}/$name';

  /// Everything that can be chosen in ⚙ > Subtitles for video [i].
  List<SubOption> _options(int i) {
    final name = widget.videos[i].name;
    return [
      for (final f in _tracks(i))
        SubOption(id: 'file:$f', label: subtitleLabel(name, f), detail: f),
      for (final t in _embedded[i]?.tracks ?? const <EmbeddedTrack>[])
        SubOption(
          id: 'track:${t.index}',
          label: embeddedTrackLabel(t),
          detail: t.isText
              ? 'Built into the video'
              : "Picture-based: can't be shown",
          enabled: t.isText,
        ),
    ];
  }

  /// A short note about built-in subtitles (still looking / no FFmpeg).
  String? _subtitleNote(int i) {
    final e = _embedded[i];
    if (e == null) return 'Looking for subtitles built into the video…';
    if (!e.available) {
      return 'Built-in subtitles need FFmpeg on the PC '
          '(winget install Gyan.FFmpeg).';
    }
    return null;
  }

  Future<ClosedCaptionFile> _captions(int i, String id) async {
    if (id.startsWith('track:')) {
      final track = int.parse(id.substring(6));
      return WebVTTCaptionFile(
        await widget.client.subtitleVtt(_pathOf(i), track),
      );
    }
    final file = id.substring(5);
    final text = await widget.client.readText(_inFolder(file));
    return file.toLowerCase().endsWith('.vtt')
        ? WebVTTCaptionFile(text)
        : SubRipCaptionFile(text);
  }

  /// Shows subtitle [id] (or none) on video [i].
  Future<void> _applySubtitle(int i, String? id) async {
    _subtitle[i] = id;
    final c = _players[i];
    if (c == null) return;
    if (id == null) {
      await c.setClosedCaptionFile(null);
      if (mounted) setState(() {});
      return;
    }
    _subLoading.add(i);
    if (mounted) setState(() {});
    try {
      await c.setClosedCaptionFile(_captions(i, id));
    } on Object {
      if (_subtitle[i] == id) _subtitle[i] = null;
      await c.setClosedCaptionFile(null);
      if (mounted && i == _index) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't load those subtitles.")),
        );
      }
    } finally {
      _subLoading.remove(i);
      if (mounted) setState(() {});
    }
  }

  /// Turns subtitles on with [id], or off with null, for the current video.
  /// Remembers on/off for the next videos.
  Future<void> _chooseSubtitle(String? id) async {
    await widget.settings.setSubtitlesOn(id != null);
    await _applySubtitle(_index, id);
  }

  /// Asks the PC for the video's built-in tracks; if subtitles are on and
  /// there's no subtitle file, picks one (phone's language first).
  Future<void> _loadEmbedded(int i) async {
    try {
      final result = await widget.client.subtitleTracks(_pathOf(i));
      _embedded[i] = result;
    } on Object {
      _embedded[i] = (available: true, tracks: const []);
    }
    if (!mounted) return;
    setState(() {});
    if (widget.settings.subtitlesOn &&
        _subtitle[i] == null &&
        _tracks(i).isEmpty) {
      final pick = defaultEmbeddedTrack(
        _embedded[i]!.tracks,
        ui.PlatformDispatcher.instance.locale.languageCode,
      );
      if (pick != null) await _applySubtitle(i, 'track:${pick.index}');
    }
  }

  String _pathOf(int i) => widget.folder.isEmpty
      ? widget.videos[i].name
      : '${widget.folder}/${widget.videos[i].name}';

  @override
  void initState() {
    super.initState();
    // Like the photo viewer: no clock/battery bar while watching.
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    // Current video first, then the neighbours.
    unawaited(() async {
      _resume = await ResumeStore.load();
      await _prepare(_index);
      _prepareNeighbours();
    }());
    // Remember how far we got, every few seconds while playing.
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_players[_index]?.value.isPlaying ?? false) _saveProgress(_index);
    });
  }

  ResumeStore? _resume;
  Timer? _saveTimer;

  /// Where each video was resumed from (shown as "Resumed at ...").
  final _resumedAt = <int, Duration>{};

  String _resumeId(int i) => ResumeStore.idFor(
    widget.client.pairing.pcId,
    _pathOf(i),
    widget.videos[i].modified,
  );

  void _saveProgress(int i) {
    final c = _players[i];
    if (c == null || !_ready.contains(i)) return;
    unawaited(_resume?.save(_resumeId(i), c.value.position, c.value.duration));
  }

  /// Positions video [i] where you left off (or at the start).
  Future<void> _seekToStart(int i, VideoPlayerController c) async {
    final saved = _resume?.positionFor(_resumeId(i));
    if (saved != null && saved < c.value.duration) {
      await c.seekTo(saved);
      _resumedAt[i] = saved;
    } else {
      await c.seekTo(Duration.zero);
      _resumedAt.remove(i);
    }
    if (mounted) setState(() {});
  }

  /// "Start over": back to 0 and forget the saved position.
  Future<void> _startOver() async {
    final i = _index;
    _resumedAt.remove(i);
    unawaited(_resume?.clear(_resumeId(i)));
    await _players[i]?.seekTo(Duration.zero);
    if (mounted) setState(() {});
  }

  void _prepareNeighbours() {
    unawaited(_prepare(_index + 1));
    unawaited(_prepare(_index - 1));
  }

  /// Loads video [i] paused at its first frame (plays it if it's current).
  Future<void> _prepare(int i) async {
    if (i < 0 || i >= widget.videos.length || _players.containsKey(i)) return;
    try {
      final url = await widget.relay.urlFor(_pathOf(i));
      if (!mounted || _players.containsKey(i)) return;
      final c = VideoPlayerController.networkUrl(url);
      _players[i] = c;
      await c.initialize();
      if (!mounted || _players[i] != c) return;
      await c.setVolume(widget.settings.videoMuted ? 0 : 1);
      await c.setLooping(widget.settings.videoLoop);
      // Subtitles: a file next to the video first; built-in tracks are
      // looked up in the background (playback doesn't wait for them).
      final files = _tracks(i);
      if (widget.settings.subtitlesOn && files.isNotEmpty) {
        unawaited(_applySubtitle(i, 'file:${files.first}'));
      }
      unawaited(_loadEmbedded(i));
      _ready.add(i);
      if (i == _index) {
        await _seekToStart(i, c);
        await c.play();
      }
      if (mounted) setState(() {});
    } on Object catch (e) {
      _errors[i] =
          "Couldn't play this video. The phone may not support its format, "
          'or the PC is unreachable.\n\n($e)';
      if (mounted) setState(() {});
    }
  }

  /// Switches to the next (+1) or previous (-1) video, if there is one.
  void _swipe(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.videos.length) return;
    _saveProgress(_index);
    unawaited(_players[_index]?.pause());
    setState(() {
      _direction = delta;
      _index = next;
    });
    final c = _players[next];
    if (c != null && _ready.contains(next)) {
      // Settings may have changed since it was loaded.
      unawaited(c.setVolume(widget.settings.videoMuted ? 0 : 1));
      unawaited(c.setLooping(widget.settings.videoLoop));
      unawaited(_seekToStart(next, c).then((_) => c.play()));
    } else {
      unawaited(_prepare(next)); // plays once loaded
    }
    _prepareNeighbours();
    _pruneFarPlayers();
  }

  /// Frees players more than one step away (after the slide has finished).
  void _pruneFarPlayers() {
    final far = [
      for (final i in _players.keys)
        if ((i - _index).abs() > 1) i,
    ];
    for (final i in far) {
      final c = _players.remove(i)!;
      _ready.remove(i);
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 500), c.dispose),
      );
    }
  }

  /// Locks full screen to the remembered landscape side.
  Future<void> _applyLandscapeSide() => SystemChrome.setPreferredOrientations([
    widget.settings.landscapeFlipped
        ? DeviceOrientation.landscapeRight
        : DeviceOrientation.landscapeLeft,
  ]);

  /// Turns full screen 180° to the other landscape side (and remembers it).
  Future<void> _flipLandscape() async {
    await widget.settings.setLandscapeFlipped(
      !widget.settings.landscapeFlipped,
    );
    await _applyLandscapeSide();
  }

  Future<void> _setFullscreen(bool on) async {
    setState(() => _fullscreen = on);
    if (on) {
      // Full screen = landscape, hiding the status and navigation bars.
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await _applyLandscapeSide();
    } else {
      // Back to portrait; the status bar stays hidden while watching.
      await SystemChrome.setPreferredOrientations([]);
    }
  }

  static Future<void> _restoreSystemUi() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations([]);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveProgress(_index);
    unawaited(_restoreSystemUi());
    for (final c in _players.values) {
      unawaited(c.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _players[_index];
    final ready = video != null && _ready.contains(_index);
    final error = _errors[_index];
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) unawaited(_setFullscreen(false));
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        // No title bar: the video gets the whole screen. Android's back
        // gesture leaves (or first exits full screen).
        // Swiping slides the next video in (already loaded at its first
        // frame), and it starts playing.
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => slideTransition(
            child,
            animation,
            currentKey: ValueKey('video-$_index'),
            direction: _direction,
          ),
          child: KeyedSubtree(
            key: ValueKey('video-$_index'),
            child: ColoredBox(
              color: Colors.black,
              child: error != null
                  ? _ErrorText(error)
                  : ready
                  ? _Player(
                      key: ValueKey(_index),
                      video: video,
                      settings: widget.settings,
                      title: _entry.name,
                      onSwipe: _swipe,
                      subtitleOptions: _options(_index),
                      subtitleId: _subtitle[_index],
                      subtitleNote: _subtitleNote(_index),
                      subtitleLoading: _subLoading.contains(_index),
                      onChooseSubtitle: _chooseSubtitle,
                      fullscreen: _fullscreen,
                      onFullscreen: () => _setFullscreen(!_fullscreen),
                      onFlip: _flipLandscape,
                      resumedAt: _resumedAt[_index],
                      onStartOver: _startOver,
                    )
                  : const Center(child: CircularProgressIndicator()),
            ),
          ),
        ),
      ),
    );
  }
}

/// Slides the new page in from the side it came from and the old one out
/// the other way. [direction] +1 = next (comes from the right), -1 = previous.
Widget slideTransition(
  Widget child,
  Animation<double> animation, {
  required Key currentKey,
  required int direction,
}) {
  final incoming = child.key == currentKey;
  final from = Offset((incoming ? direction : -direction).toDouble(), 0);
  return SlideTransition(
    position: Tween(begin: from, end: Offset.zero).animate(animation),
    child: child,
  );
}

/// The video with our own controls: one bar at the bottom with play/pause,
/// times, the seek bar and full screen. A tap shows the bar for 4 seconds
/// (or hides it). No double-tap gestures, so every tap reacts immediately.
class _Player extends StatefulWidget {
  const _Player({
    super.key,
    required this.video,
    required this.settings,
    required this.title,
    required this.onSwipe,
    required this.subtitleOptions,
    required this.subtitleId,
    required this.subtitleNote,
    required this.subtitleLoading,
    required this.onChooseSubtitle,
    required this.fullscreen,
    required this.onFullscreen,
    required this.onFlip,
    required this.resumedAt,
    required this.onStartOver,
  });

  final VideoPlayerController video;
  final AppSettings settings;
  final String title;

  /// +1 = next video, -1 = previous (from a quick horizontal swipe).
  final ValueChanged<int> onSwipe;

  /// Subtitle files for this video, the one shown (null = off), and how to
  /// switch.
  final List<SubOption> subtitleOptions;
  final String? subtitleId;
  final String? subtitleNote;
  final bool subtitleLoading;
  final Future<void> Function(String?) onChooseSubtitle;
  final bool fullscreen;
  final VoidCallback onFullscreen;

  /// Full screen only: turn to the other landscape side.
  final VoidCallback onFlip;

  /// Set when the video continued where you left off.
  final Duration? resumedAt;
  final VoidCallback onStartOver;

  @override
  State<_Player> createState() => _PlayerState();
}

class _PlayerState extends State<_Player> with SingleTickerProviderStateMixin {
  /// Hidden until the user taps (also after swiping to another video).
  bool _controlsVisible = false;

  /// The "Resumed at ... · Start over" note shows for a few seconds.
  bool _resumeNote = true;
  late final Timer _resumeNoteTimer = Timer(const Duration(seconds: 7), () {
    if (mounted) setState(() => _resumeNote = false);
  });
  Timer? _hideTimer;

  /// While the seek bar is dragged: where the thumb is (in ms).
  double? _scrubMs;

  VideoPlayerController get _v => widget.video;
  final _zoom = TransformationController();

  @override
  void didUpdateWidget(_Player old) {
    super.didUpdateWidget(old);
    // Rotating to or from full screen changes the layout: start unzoomed.
    if (old.fullscreen != widget.fullscreen) _zoom.value = Matrix4.identity();
  }

  @override
  void initState() {
    super.initState();
    _v.addListener(_onVideo);
  }

  @override
  void dispose() {
    _resumeNoteTimer.cancel();
    _v.removeListener(_onVideo);
    _hideTimer?.cancel();
    _zoomAnim.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _onVideo() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _scrubMs == null) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  late final AnimationController _zoomAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..addListener(() => _zoom.value = _zoomTween!.evaluate(_zoomCurve));
  late final Animation<double> _zoomCurve = CurvedAnimation(
    parent: _zoomAnim,
    curve: Curves.easeOutCubic,
  );
  Matrix4Tween? _zoomTween;
  DateTime? _lastTap;
  Offset? _lastTapAt;

  /// Taps are handled by hand so a single tap reacts at once (no waiting to
  /// see if a second one follows). A quick second tap near the first undoes
  /// the first tap's show/hide and toggles zoom instead.
  void _onTapUp(TapUpDetails d) {
    final now = DateTime.now();
    final isDouble =
        _lastTap != null &&
        now.difference(_lastTap!) < const Duration(milliseconds: 300) &&
        (d.localPosition - _lastTapAt!).distance < 60;
    _lastTap = isDouble ? null : now;
    _lastTapAt = d.localPosition;
    _toggleControls();
    if (isDouble) _toggleZoom(d.localPosition);
  }

  void _toggleZoom(Offset at) {
    final Matrix4 target;
    if (_zoom.value.getMaxScaleOnAxis() > 1.01) {
      target = Matrix4.identity();
    } else {
      const scale = 2.5;
      target = Matrix4.identity()
        ..translateByDouble(-at.dx * (scale - 1), -at.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
    _zoomTween = Matrix4Tween(begin: _zoom.value.clone(), end: target);
    _zoomAnim.forward(from: 0);
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _togglePlay() {
    final v = _v.value;
    if (v.isPlaying) {
      unawaited(_v.pause());
    } else {
      if (v.position >= v.duration) unawaited(_v.seekTo(Duration.zero));
      unawaited(_v.play());
    }
    _scheduleHide();
  }

  void _skip(int seconds) {
    final v = _v.value;
    var to = v.position + Duration(seconds: seconds);
    if (to < Duration.zero) to = Duration.zero;
    if (to > v.duration) to = v.duration;
    unawaited(_v.seekTo(to));
    _scheduleHide();
  }

  bool get _muted => widget.settings.videoMuted;

  // Swipe detection: one finger, not zoomed, fast and mostly sideways.
  int _maxPointers = 0;
  bool _zoomedAtStart = false;

  void _onInteractionEnd(ScaleEndDetails d) {
    final v = d.velocity.pixelsPerSecond;
    if (_maxPointers == 1 &&
        !_zoomedAtStart &&
        v.dx.abs() > 500 &&
        v.dx.abs() > v.dy.abs() * 1.5) {
      widget.onSwipe(v.dx < 0 ? 1 : -1);
    }
  }

  Future<void> _toggleMute() async {
    final mute = !_muted;
    await widget.settings.setVideoMuted(mute);
    await _v.setVolume(mute ? 0 : 1);
    if (mounted) setState(() {});
    _scheduleHide();
  }

  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  Future<void> _openSettings() async {
    _hideTimer?.cancel();
    final current = _v.value.playbackSpeed;
    final speed = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            // Loop: remembered like mute, applied right away.
            StatefulBuilder(
              builder: (context, setSheet) => SwitchListTile(
                secondary: const Icon(Icons.repeat),
                title: const Text('Loop video'),
                subtitle: const Text('Start again from the beginning'),
                value: widget.settings.videoLoop,
                onChanged: (on) async {
                  await widget.settings.setVideoLoop(on);
                  await _v.setLooping(on);
                  setSheet(() {});
                },
              ),
            ),
            const Divider(),
            // Collapsed until tapped; shows the current speed meanwhile.
            ExpansionTile(
              leading: const Icon(Icons.speed),
              title: const Text('Playback speed'),
              subtitle: Text(current == 1.0 ? 'Normal' : '${current}x'),
              shape: const Border(),
              collapsedShape: const Border(),
              children: [
                for (final sp in _speeds)
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 56, right: 16),
                    leading: Icon(
                      sp == current
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(sp == 1.0 ? 'Normal' : '${sp}x'),
                    onTap: () => Navigator.pop(context, sp),
                  ),
              ],
            ),
            const Divider(),
            // Subtitles (collapsed, like speed).
            if (widget.subtitleOptions.isEmpty)
              ListTile(
                enabled: false,
                leading: const Icon(Icons.subtitles_off_outlined),
                title: const Text('Subtitles: none found'),
                subtitle: Text(
                  widget.subtitleNote ??
                      'No built-in subtitles, and no subtitle file next to '
                          'the video (e.g. Movie.srt for Movie.mp4).',
                ),
              )
            else
              ExpansionTile(
                leading: const Icon(Icons.subtitles_outlined),
                title: const Text('Subtitles'),
                subtitle: Text(
                  widget.subtitleLoading
                      ? 'Loading…'
                      : widget.subtitleOptions
                                .where((o) => o.id == widget.subtitleId)
                                .firstOrNull
                                ?.label ??
                            'Off',
                ),
                shape: const Border(),
                collapsedShape: const Border(),
                children: [
                  for (final o in <SubOption?>[null, ...widget.subtitleOptions])
                    ListTile(
                      enabled: o?.enabled ?? true,
                      contentPadding: const EdgeInsets.only(
                        left: 56,
                        right: 16,
                      ),
                      leading: Icon(
                        o?.id == widget.subtitleId
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(o?.label ?? 'Off'),
                      subtitle: o?.detail == null ? null : Text(o!.detail!),
                      onTap: () {
                        Navigator.pop(context);
                        unawaited(widget.onChooseSubtitle(o?.id));
                      },
                    ),
                  if (widget.subtitleNote != null)
                    ListTile(
                      enabled: false,
                      contentPadding: const EdgeInsets.only(
                        left: 56,
                        right: 16,
                      ),
                      title: Text(widget.subtitleNote!),
                    ),
                ],
              ),
            ExpansionTile(
              leading: const Icon(Icons.format_size),
              title: const Text('Subtitle size'),
              subtitle: Text(
                AppSettings.subtitleSizes.entries
                    .firstWhere(
                      (e) => e.value == widget.settings.subtitleSize,
                      orElse: () => const MapEntry('Medium', 20),
                    )
                    .key,
              ),
              shape: const Border(),
              collapsedShape: const Border(),
              children: [
                for (final MapEntry(key: label, value: size)
                    in AppSettings.subtitleSizes.entries)
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 56, right: 16),
                    leading: Icon(
                      size == widget.settings.subtitleSize
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(label, style: TextStyle(fontSize: size * 0.8)),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(widget.settings.setSubtitleSize(size));
                      setState(() {});
                    },
                  ),
              ],
            ),
            const Divider(),
            const ListTile(
              enabled: false,
              leading: Icon(Icons.high_quality_outlined),
              title: Text('Quality: Original'),
              subtitle: Text(
                'The video streams as-is from your PC. Lower '
                'qualities would need the PC to convert it first.',
              ),
            ),
          ],
        ),
      ),
    );
    if (speed != null) await _v.setPlaybackSpeed(speed);
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final value = _v.value;
    final durationMs = value.duration.inMilliseconds.toDouble();
    final positionMs =
        (_scrubMs ??
                value.position.inMilliseconds.toDouble().clamp(0, durationMs))
            .toDouble();
    final scrubbing = _scrubMs != null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Pinch to zoom into the video while it plays; drag to move
          // around when zoomed. Only the picture zooms, never the controls.
          InteractiveViewer(
            transformationController: _zoom,
            maxScale: 5,
            onInteractionStart: (d) {
              _zoomAnim.stop();
              _maxPointers = d.pointerCount;
              _zoomedAtStart = _zoom.value.getMaxScaleOnAxis() > 1.01;
            },
            onInteractionUpdate: (d) =>
                _maxPointers = max(_maxPointers, d.pointerCount),
            onInteractionEnd: _onInteractionEnd,
            child: Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio,
                child: VideoPlayer(_v),
              ),
            ),
          ),
          if (value.isBuffering && !scrubbing)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          if (widget.resumedAt != null &&
              _resumeNote &&
              _resumeNoteTimer.isActive)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 64,
              left: 0,
              right: 0,
              child: Center(
                child: Material(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(24),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 16, right: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Resumed at '
                          '${_fmt(widget.resumedAt!.inMilliseconds.toDouble())}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() => _resumeNote = false);
                            widget.onStartOver();
                          },
                          child: const Text('Start over'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          // Subtitles sit above the control bar when it's showing.
          if (widget.subtitleLoading)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 150),
              left: 16,
              right: 16,
              bottom: _controlsVisible ? 96 : 28,
              child: const IgnorePointer(
                child: Text(
                  'Loading subtitles…',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            )
          else if (widget.subtitleId != null &&
              plainCaption(value.caption.text).isNotEmpty)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 150),
              left: 16,
              right: 16,
              bottom: _controlsVisible ? 96 : 28,
              child: IgnorePointer(
                child: Text(
                  plainCaption(value.caption.text),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: widget.settings.subtitleSize,
                    height: 1.25,
                    shadows: const [
                      Shadow(blurRadius: 3),
                      Shadow(offset: Offset(1, 1), blurRadius: 2),
                      Shadow(offset: Offset(-1, -1), blurRadius: 2),
                    ],
                  ),
                ),
              ),
            ),
          AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // File name and back arrow come and go with the bar.
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: _TopBar(
                      title: widget.title,
                      onBack: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  // All controls live in one bar at the very bottom.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _BottomBar(
                      playing: value.isPlaying,
                      onPlayPause: _togglePlay,
                      onSkip: _skip,
                      onSettings: _openSettings,
                      muted: _muted,
                      onMute: _toggleMute,
                      positionMs: positionMs,
                      durationMs: durationMs,
                      bufferedMs: value.buffered.isEmpty
                          ? 0
                          : value.buffered.last.end.inMilliseconds.toDouble(),
                      fullscreen: widget.fullscreen,
                      onFullscreen: widget.onFullscreen,
                      onFlip: widget.onFlip,
                      onScrubStart: (ms) {
                        _hideTimer?.cancel();
                        setState(() => _scrubMs = ms);
                      },
                      onScrub: (ms) => setState(() => _scrubMs = ms),
                      onScrubEnd: (ms) async {
                        await _v.seekTo(Duration(milliseconds: ms.round()));
                        if (mounted) setState(() => _scrubMs = null);
                        _scheduleHide();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.onBack});
  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.black87, Colors.transparent],
      ),
    ),
    padding: const EdgeInsets.only(bottom: 24),
    child: SafeArea(
      bottom: false,
      child: Row(
        children: [
          IconButton(
            color: Colors.white,
            tooltip: 'Back',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
    ),
  );
}

/// Everything in one row: play/pause, -10 s, +10 s, the seek bar (times
/// underneath), playback settings, full screen.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.playing,
    required this.onPlayPause,
    required this.onSkip,
    required this.onSettings,
    required this.muted,
    required this.onMute,
    required this.positionMs,
    required this.durationMs,
    required this.bufferedMs,
    required this.fullscreen,
    required this.onFullscreen,
    required this.onFlip,
    required this.onScrubStart,
    required this.onScrub,
    required this.onScrubEnd,
  });

  final bool playing;
  final VoidCallback onPlayPause;
  final ValueChanged<int> onSkip;
  final VoidCallback onSettings;
  final bool muted;
  final VoidCallback onMute;
  final double positionMs;
  final double durationMs;
  final double bufferedMs;
  final bool fullscreen;
  final VoidCallback onFullscreen;
  final VoidCallback onFlip;
  final ValueChanged<double> onScrubStart;
  final ValueChanged<double> onScrub;
  final ValueChanged<double> onScrubEnd;

  @override
  Widget build(BuildContext context) {
    const text = TextStyle(color: Colors.white, fontSize: 11);
    final max = durationMs <= 0 ? 1.0 : durationMs;
    // In portrait the bar is narrow: the left buttons sit closer together.
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    Widget button(
      IconData icon,
      String tip,
      VoidCallback onPressed, {
      bool tight = false,
    }) => IconButton(
      color: Colors.white,
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      // Portrait: every button is narrow so the seek bar gets the room.
      padding: portrait ? EdgeInsets.zero : null,
      constraints: portrait
          ? const BoxConstraints(minWidth: 30, minHeight: 44)
          : null,
      iconSize: portrait ? 22 : null,
      onPressed: onPressed,
      icon: Icon(icon),
    );
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 4),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            const SizedBox(width: 4),
            button(
              playing ? Icons.pause : Icons.play_arrow,
              playing ? 'Pause' : 'Play',
              onPlayPause,
              tight: true,
            ),
            // -10/+10 only in landscape; portrait keeps the seek bar wide.
            if (!portrait) ...[
              button(Icons.replay_10, 'Back 10 seconds', () => onSkip(-10)),
              button(Icons.forward_10, 'Forward 10 seconds', () => onSkip(10)),
            ],
            SizedBox(width: portrait ? 6 : 4),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: Colors.tealAccent,
                      inactiveTrackColor: Colors.white24,
                      secondaryActiveTrackColor: Colors.white54,
                      thumbColor: Colors.tealAccent,
                      overlayShape: SliderComponentShape.noOverlay,
                      // Thicker bar and a bigger handle: easier to grab.
                      trackHeight: 5,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 9,
                      ),
                    ),
                    child: Slider(
                      max: max,
                      value: positionMs.clamp(0, max),
                      secondaryTrackValue: bufferedMs.clamp(0, max),
                      onChangeStart: onScrubStart,
                      onChanged: onScrub,
                      onChangeEnd: onScrubEnd,
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(positionMs), style: text),
                      Text(_fmt(durationMs), style: text),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(width: portrait ? 6 : 0),
            button(
              muted ? Icons.volume_off : Icons.volume_up,
              muted ? 'Unmute' : 'Mute',
              onMute,
            ),
            button(Icons.settings, 'Playback settings', onSettings),
            if (fullscreen)
              button(
                Icons.screen_rotation_alt,
                'Flip to the other side',
                onFlip,
              ),
            button(
              fullscreen ? Icons.fullscreen_exit : Icons.screen_rotation,
              fullscreen ? 'Exit full screen' : 'Full screen (landscape)',
              onFullscreen,
            ),
          ],
        ),
      ),
    );
  }
}

String _fmt(double ms) {
  final d = Duration(milliseconds: ms.round());
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white70),
      ),
    ),
  );
}
