import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';
import 'package:video_player/video_player.dart';

import 'app_settings.dart';
import 'browser_page.dart';
import 'keep_awake.dart';
import 'thumbnails.dart';
import 'video_page.dart' show slideTransition;
import 'video_relay.dart';

/// Plays every photo, GIF and video of one folder in order (or shuffled),
/// then starts over. Photos and GIFs stay for the time set in Settings; videos play to
/// the end. Tap to show the controls (they hide again after 4 seconds).
class SlideshowPage extends StatefulWidget {
  const SlideshowPage({
    super.key,
    required this.thumbs,
    required this.relay,
    required this.settings,
    required this.folder,
    required this.items,
  });

  final ThumbnailCache thumbs;
  final VideoRelay relay;
  final AppSettings settings;
  final String folder;
  final List<RemoteEntry> items;

  @override
  State<SlideshowPage> createState() => _SlideshowPageState();
}

class _SlideshowPageState extends State<SlideshowPage> {
  /// Play order (indexes into the items) and where we are in it. In
  /// shuffle mode it's a random order without repeats, reshuffled each round.
  late List<int> _order = _makeOrder();
  int _pos = 0;
  int get _index => _order[_pos];
  final _random = Random();
  bool _playing = true;
  bool _controls = false;

  /// Video players for the current item and the next one, loaded ahead so
  /// the next video's real first frame is ready (no preview-image flicker).
  final _videos = <int, VideoPlayerController>{};
  final _videoReady = <int>{};
  final _videoFailed = <int>{};
  int? _shownIndex;
  int? _endHandledFor;

  /// The ⏮/⏭ buttons switch instantly (no slide or fade).
  bool _instant = false;
  Timer? _slideTimer;
  Timer? _hideTimer;

  RemoteEntry get _current => widget.items[_index];

  bool get _shuffle => widget.settings.slideShuffle;

  /// Normal order, or a shuffled one. [first] stays first (so turning
  /// shuffle on keeps showing the current item); [avoidFirst] isn't first
  /// (so a new round doesn't repeat the item just shown).
  List<int> _makeOrder({int? first, int? avoidFirst}) {
    final order = List<int>.generate(widget.items.length, (i) => i);
    if (!_shuffle) return order;
    order.shuffle(_random);
    if (first != null) {
      order
        ..remove(first)
        ..insert(0, first);
    } else if (avoidFirst != null &&
        order.length > 1 &&
        order.first == avoidFirst) {
      order
        ..removeAt(0)
        ..add(avoidFirst);
    }
    return order;
  }

  void _toggleShuffle() {
    final current = _index;
    unawaited(
      widget.settings.setSlideShuffle(!_shuffle).then((_) {
        if (!mounted) return;
        setState(() {
          _order = _makeOrder(first: current);
          _pos = _order.indexOf(current);
        });
      }),
    );
    _showControls();
  }

  String _path(RemoteEntry e) => joinPath(widget.folder, e.name);

  PcImage _image(RemoteEntry e) =>
      PcImage(widget.thumbs, _path(e), e, isGif(e.name) ? 0 : 2048);

  @override
  void initState() {
    super.initState();
    KeepAwake.hold(this);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    _startSlide();
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _hideTimer?.cancel();
    for (final c in _videos.values) {
      unawaited(c.dispose());
    }
    KeepAwake.release(this);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  int get _nextIndex => _order[(_pos + 1) % _order.length];

  /// Loads video [i] paused at its first frame (plays it if it's showing).
  Future<void> _prepareVideo(int i) async {
    if (_videos.containsKey(i) || _videoFailed.contains(i)) return;
    if (widget.items[i].kind != MediaKind.video) return;
    VideoPlayerController? c;
    try {
      final url = await widget.relay.urlFor(_path(widget.items[i]));
      if (!mounted || _videos.containsKey(i)) return;
      c = VideoPlayerController.networkUrl(url);
      _videos[i] = c;
      await c.initialize();
      if (!mounted || _videos[i] != c) return;
      await c.setVolume(widget.settings.videoMuted ? 0 : 1);
      final controller = c;
      controller.addListener(() => _onVideoTick(i, controller));
      _videoReady.add(i);
      if (i == _index && _playing) await c.play();
      if (mounted) setState(() {});
    } on Object {
      _videoFailed.add(i);
      if (_videos[i] == c) _videos.remove(i);
      // Can't play this one: skip it after a moment.
      if (mounted && i == _index) {
        Timer(const Duration(seconds: 2), () {
          if (mounted && _index == i) _next();
        });
      }
    }
  }

  void _onVideoTick(int i, VideoPlayerController c) {
    if (i != _index || _endHandledFor == i) return;
    final v = c.value;
    if (v.isInitialized &&
        !v.isPlaying &&
        v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 200)) {
      _endHandledFor = i;
      _next();
    }
  }

  /// Keeps the current and next videos loaded, plays only the current one
  /// (from the start when it just came on screen), frees the rest.
  void _syncVideos() {
    final current = _index;
    final arrived = _shownIndex != current;
    _shownIndex = current;
    if (arrived) _endHandledFor = null;
    unawaited(_prepareVideo(current));
    unawaited(_prepareVideo(_nextIndex));
    for (final MapEntry(key: i, value: c) in _videos.entries) {
      if (i != current && c.value.isPlaying) unawaited(c.pause());
    }
    final c = _videos[current];
    if (c != null && _videoReady.contains(current)) {
      if (arrived) {
        unawaited(
          c.seekTo(Duration.zero).then((_) {
            if (_playing && _index == current) unawaited(c.play());
          }),
        );
      } else {
        unawaited(_playing ? c.play() : c.pause());
      }
    } else if (_videoFailed.contains(current) && _playing) {
      Timer(const Duration(seconds: 2), () {
        if (mounted && _index == current) _next();
      });
    }
    // Free players we no longer need, after any transition has finished.
    Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      final keep = {_index, _nextIndex};
      for (final i in _videos.keys.where((k) => !keep.contains(k)).toList()) {
        _videoReady.remove(i);
        unawaited(_videos.remove(i)!.dispose());
      }
    });
  }

  /// Photos get a timer; videos advance themselves when they end.
  void _startSlide() {
    _slideTimer?.cancel();
    _syncVideos();
    if (_playing && _current.kind != MediaKind.video) {
      _slideTimer = Timer(
        Duration(seconds: widget.settings.slideSeconds),
        _next,
      );
    }
    // Load the next photo ahead of time so the change is instant.
    final next = widget.items[_order[(_pos + 1) % _order.length]];
    if (next.kind == MediaKind.image) {
      unawaited(precacheImage(_image(next), context, onError: (_, _) {}));
    }
  }

  /// +1/-1 when the user swiped or tapped next/previous (slide), 0 for the
  /// automatic advance (crossfade).
  int _direction = 0;

  void _go(int delta, {bool manual = true, bool instant = false}) {
    setState(() {
      _instant = instant;
      _direction = manual ? delta : 0;
      final n = _order.length;
      final p = _pos + delta;
      if (p >= n && _shuffle) {
        // Next round: a fresh random order.
        _order = _makeOrder(avoidFirst: _index);
        _pos = 0;
      } else {
        _pos = ((p % n) + n) % n;
      }
    });
    _startSlide();
  }

  void _next() => _go(1, manual: false);

  void _togglePlay() {
    setState(() => _playing = !_playing);
    _startSlide();
    _showControls();
  }

  void _showControls() {
    setState(() => _controls = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controls = false);
    });
  }

  void _onTap() {
    if (_controls) {
      _hideTimer?.cancel();
      setState(() => _controls = false);
    } else {
      _showControls();
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = _current;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        // Swipe left/right for the next/previous item.
        onHorizontalDragEnd: (d) {
          final vx = d.primaryVelocity ?? 0;
          if (vx.abs() > 300) _go(vx < 0 ? 1 : -1);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: _instant
                  ? Duration.zero
                  : Duration(milliseconds: _direction == 0 ? 600 : 320),
              transitionBuilder: (child, animation) => _direction == 0
                  ? FadeTransition(opacity: animation, child: child)
                  : slideTransition(
                      child,
                      animation,
                      currentKey: ValueKey(_index),
                      direction: _direction,
                    ),
              child: KeyedSubtree(
                key: ValueKey(_index),
                child: e.kind == MediaKind.video
                    ? _VideoFrame(
                        controller: _videos[_index],
                        ready: _videoReady.contains(_index),
                      )
                    : Image(
                        image: _image(e),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white38,
                            size: 48,
                          ),
                        ),
                      ),
              ),
            ),
            AnimatedOpacity(
              opacity: _controls ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: IgnorePointer(
                ignoring: !_controls,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _Bar(
                        top: true,
                        child: Row(
                          children: [
                            IconButton(
                              color: Colors.white,
                              tooltip: 'Back',
                              onPressed: () => Navigator.of(context).maybePop(),
                              icon: const Icon(Icons.arrow_back),
                            ),
                            Expanded(
                              child: Text(
                                e.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: Text(
                                '${_pos + 1} / ${widget.items.length}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: _Bar(
                        top: false,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              color: Colors.white,
                              iconSize: 32,
                              tooltip: 'Previous',
                              onPressed: () {
                                _go(-1, instant: true);
                                _showControls();
                              },
                              icon: const Icon(Icons.skip_previous),
                            ),
                            const SizedBox(width: 24),
                            IconButton(
                              color: Colors.white,
                              iconSize: 40,
                              tooltip: _playing ? 'Pause' : 'Play',
                              onPressed: _togglePlay,
                              icon: Icon(
                                _playing ? Icons.pause : Icons.play_arrow,
                              ),
                            ),
                            const SizedBox(width: 24),
                            IconButton(
                              color: Colors.white,
                              iconSize: 32,
                              tooltip: 'Next',
                              onPressed: () {
                                _go(1, instant: true);
                                _showControls();
                              },
                              icon: const Icon(Icons.skip_next),
                            ),
                            const SizedBox(width: 24),
                            IconButton(
                              color: _shuffle
                                  ? Colors.tealAccent
                                  : Colors.white,
                              iconSize: 28,
                              tooltip: _shuffle ? 'Shuffle on' : 'Shuffle off',
                              onPressed: _toggleShuffle,
                              icon: Icon(
                                _shuffle
                                    ? Icons.shuffle_on_outlined
                                    : Icons.shuffle,
                              ),
                            ),
                            const SizedBox(width: 24),
                            // Same remembered setting as the video player.
                            IconButton(
                              color: Colors.white,
                              iconSize: 28,
                              tooltip: widget.settings.videoMuted
                                  ? 'Unmute'
                                  : 'Mute',
                              onPressed: () async {
                                await widget.settings.setVideoMuted(
                                  !widget.settings.videoMuted,
                                );
                                final volume = widget.settings.videoMuted
                                    ? 0.0
                                    : 1.0;
                                for (final c in _videos.values) {
                                  unawaited(c.setVolume(volume));
                                }
                                if (mounted) setState(() {});
                                _showControls();
                              },
                              icon: Icon(
                                widget.settings.videoMuted
                                    ? Icons.volume_off
                                    : Icons.volume_up,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.top, required this.child});
  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: top ? Alignment.topCenter : Alignment.bottomCenter,
        end: top ? Alignment.bottomCenter : Alignment.topCenter,
        colors: const [Colors.black87, Colors.transparent],
      ),
    ),
    padding: EdgeInsets.only(top: top ? 0 : 24, bottom: top ? 24 : 8),
    child: SafeArea(top: top, bottom: !top, child: child),
  );
}

/// Shows a slideshow video whose player the page loaded ahead of time.
class _VideoFrame extends StatelessWidget {
  const _VideoFrame({required this.controller, required this.ready});
  final VideoPlayerController? controller;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null || !ready) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: VideoPlayer(c),
      ),
    );
  }
}
