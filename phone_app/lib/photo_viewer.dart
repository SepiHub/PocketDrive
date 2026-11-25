import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'browser_page.dart';
import 'thumbnails.dart';

/// Full-screen photos of one folder: swipe between them, pinch or
/// double-tap to zoom.
///
/// Swiping and zooming are handled by ONE gesture (the zoom view's), so a
/// pinch never has to win a race against the page swipe: the pages can't be
/// dragged on their own, and a one-finger drag on an unzoomed photo moves
/// the pages by hand. A second finger cancels the swipe and zooms instead.
///
/// Shows a large preview (2048 px) made by the PC rather than the original,
/// which loads faster and also works for formats like HEIC.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({
    super.key,
    required this.thumbs,
    required this.folder,
    required this.photos,
    required this.initialIndex,
  });

  final ThumbnailCache thumbs;
  final String folder;
  final List<RemoteEntry> photos;
  final int initialIndex;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _swiping = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  /// GIFs load the original file so they animate; other photos use the
  /// PC's 2048 px preview.
  int _fullSize(int i) => isGif(widget.photos[i].name) ? 0 : 2048;

  PcImage _image(int i, int size) => PcImage(
    widget.thumbs,
    joinPath(widget.folder, widget.photos[i].name),
    widget.photos[i],
    size,
  );

  void _swipeBy(double dx) {
    if (!_pages.hasClients) return;
    _swiping = true;
    final pos = _pages.position;
    _pages.jumpTo(
      (pos.pixels - dx)
          .clamp(pos.minScrollExtent, pos.maxScrollExtent)
          .toDouble(),
    );
  }

  /// Finishes a swipe: a quick flick or dragging past 25% changes photo.
  void _swipeEnd(double velocityX) {
    if (!_swiping || !_pages.hasClients) return;
    _swiping = false;
    final page = _pages.page ?? _index.toDouble();
    var target = _index;
    if (velocityX < -400 || page > _index + 0.25) target = _index + 1;
    if (velocityX > 400 || page < _index - 0.25) target = _index - 1;
    target = target.clamp(0, widget.photos.length - 1);
    _pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _swipeCancel() {
    if (!_swiping) return;
    _swiping = false;
    _pages.animateToPage(
      _index,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black54,
        foregroundColor: Colors.white,
        title: Text(photo.name, overflow: TextOverflow.ellipsis),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text('${_index + 1} / ${widget.photos.length}'),
            ),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pages,
        // Never dragged directly; see the class comment.
        physics: const NeverScrollableScrollPhysics(),
        itemCount: widget.photos.length,
        onPageChanged: (i) {
          setState(() => _index = i);
          // Warm up the neighbours so swiping feels instant.
          for (final n in [i - 1, i + 1]) {
            if (n >= 0 && n < widget.photos.length) {
              precacheImage(
                _image(n, _fullSize(n)),
                context,
                onError: (_, _) {},
              );
            }
          }
        },
        itemBuilder: (context, i) => _ZoomablePhoto(
          preview: _image(i, 256),
          full: _image(i, _fullSize(i)),
          onSwipe: _swipeBy,
          onSwipeEnd: _swipeEnd,
          onSwipeCancel: _swipeCancel,
        ),
      ),
    );
  }
}

class _ZoomablePhoto extends StatefulWidget {
  const _ZoomablePhoto({
    required this.preview,
    required this.full,
    required this.onSwipe,
    required this.onSwipeEnd,
    required this.onSwipeCancel,
  });

  final PcImage preview;
  final PcImage full;
  final ValueChanged<double> onSwipe;
  final ValueChanged<double> onSwipeEnd;
  final VoidCallback onSwipeCancel;

  @override
  State<_ZoomablePhoto> createState() => _ZoomablePhotoState();
}

class _ZoomablePhotoState extends State<_ZoomablePhoto>
    with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _zoomAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  )..addListener(() => _transform.value = _zoomTween!.evaluate(_zoomCurve));
  late final Animation<double> _zoomCurve = CurvedAnimation(
    parent: _zoomAnimation,
    curve: Curves.easeOutCubic,
  );
  Matrix4Tween? _zoomTween;
  TapDownDetails? _doubleTap;
  bool _multiTouch = false;

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  @override
  void dispose() {
    _zoomAnimation.dispose();
    _transform.dispose();
    super.dispose();
  }

  /// Double-tap glides in on the tapped spot, or back out to the whole photo.
  void _toggleZoom() {
    final Matrix4 target;
    if (_zoomed) {
      target = Matrix4.identity();
    } else {
      final pos = _doubleTap?.localPosition ?? Offset.zero;
      const scale = 2.5;
      target = Matrix4.identity()
        ..translateByDouble(-pos.dx * (scale - 1), -pos.dy * (scale - 1), 0, 1)
        ..scaleByDouble(scale, scale, 1, 1);
    }
    _zoomTween = Matrix4Tween(begin: _transform.value.clone(), end: target);
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (d) => _doubleTap = d,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        maxScale: 6,
        onInteractionStart: (d) {
          _zoomAnimation.stop(); // a new touch takes over from the glide
          _multiTouch = d.pointerCount > 1;
        },
        onInteractionUpdate: (d) {
          if (d.pointerCount > 1) {
            // Second finger: this is a pinch, not a swipe.
            if (!_multiTouch) widget.onSwipeCancel();
            _multiTouch = true;
          } else if (!_multiTouch && !_zoomed) {
            widget.onSwipe(d.focalPointDelta.dx);
          }
        },
        onInteractionEnd: (d) {
          if (!_multiTouch && !_zoomed) {
            widget.onSwipeEnd(d.velocity.pixelsPerSecond.dx);
          }
          _multiTouch = false;
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // The small grid preview shows at once (it's cached), then the
            // sharp version fades in on top.
            Image(
              image: widget.preview,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
            Image(
              image: widget.full,
              fit: BoxFit.contain,
              frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: child,
              ),
              errorBuilder: (_, _, _) => const Center(
                child: Text(
                  "Couldn't load this photo.",
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
