import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_settings.dart';
import 'browser_page.dart';
import 'thumbnails.dart';
import 'video_relay.dart';

/// Plays every photo, GIF and video of one folder in order, then starts
/// over. Photos and GIFs stay for the time set in Settings; videos play to
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
  int _index = 0;
  bool _playing = true;
  bool _controls = false;
  Timer? _slideTimer;
  Timer? _hideTimer;

  RemoteEntry get _current => widget.items[_index];
  String _path(RemoteEntry e) => joinPath(widget.folder, e.name);

  PcImage _image(RemoteEntry e) =>
      PcImage(widget.thumbs, _path(e), e, isGif(e.name) ? 0 : 2048);

  @override
  void initState() {
    super.initState();
    unawaited(WakelockPlus.enable());
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    _startSlide();
  }

  @override
  void dispose() {
    _slideTimer?.cancel();
    _hideTimer?.cancel();
    unawaited(WakelockPlus.disable());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  /// Photos get a timer; videos advance themselves when they end.
  void _startSlide() {
    _slideTimer?.cancel();
    if (_playing && _current.kind != MediaKind.video) {
      _slideTimer = Timer(
        Duration(seconds: widget.settings.slideSeconds),
        _next,
      );
    }
    // Load the next photo ahead of time so the change is instant.
    final next = widget.items[(_index + 1) % widget.items.length];
    if (next.kind == MediaKind.image) {
      unawaited(precacheImage(_image(next), context, onError: (_, _) {}));
    }
  }

  void _go(int delta) {
    setState(() {
      _index = (_index + delta) % widget.items.length;
      if (_index < 0) _index += widget.items.length;
    });
    _startSlide();
  }

  void _next() => _go(1);

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
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              child: KeyedSubtree(
                key: ValueKey(_index),
                child: e.kind == MediaKind.video
                    ? _SlideVideo(
                        relay: widget.relay,
                        path: _path(e),
                        preview: PcImage(widget.thumbs, _path(e), e, 256),
                        playing: _playing,
                        onFinished: _next,
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
                                '${_index + 1} / ${widget.items.length}',
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
                                _go(-1);
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
                                _go(1);
                                _showControls();
                              },
                              icon: const Icon(Icons.skip_next),
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

/// A video inside the slideshow: plays once, then calls [onFinished].
class _SlideVideo extends StatefulWidget {
  const _SlideVideo({
    required this.relay,
    required this.path,
    required this.preview,
    required this.playing,
    required this.onFinished,
  });

  final VideoRelay relay;
  final String path;
  final PcImage preview;
  final bool playing;
  final VoidCallback onFinished;

  @override
  State<_SlideVideo> createState() => _SlideVideoState();
}

class _SlideVideoState extends State<_SlideVideo> {
  VideoPlayerController? _video;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final video = VideoPlayerController.networkUrl(
        await widget.relay.urlFor(widget.path),
      );
      _video = video;
      await video.initialize();
      if (!mounted) return;
      video.addListener(_onTick);
      if (widget.playing) await video.play();
      setState(() {});
    } on Object {
      // Can't play this one: skip it after a moment.
      if (mounted) Timer(const Duration(seconds: 2), _finish);
    }
  }

  void _onTick() {
    final v = _video!.value;
    if (v.isInitialized &&
        !v.isPlaying &&
        v.duration > Duration.zero &&
        v.position >= v.duration - const Duration(milliseconds: 200)) {
      _finish();
    }
  }

  void _finish() {
    if (_finished || !mounted) return;
    _finished = true;
    widget.onFinished();
  }

  @override
  void didUpdateWidget(_SlideVideo old) {
    super.didUpdateWidget(old);
    final v = _video;
    if (v != null && v.value.isInitialized && old.playing != widget.playing) {
      unawaited(widget.playing ? v.play() : v.pause());
    }
  }

  @override
  void dispose() {
    _video?.removeListener(_onTick);
    unawaited(_video?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    if (v == null || !v.value.isInitialized) {
      return Image(
        image: widget.preview,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return Center(
      child: AspectRatio(
        aspectRatio: v.value.aspectRatio,
        child: VideoPlayer(v),
      ),
    );
  }
}
