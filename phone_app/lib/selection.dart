import 'dart:async';
import 'dart:math';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// Marks a grid tile (by index) or a folder row (by name) so a finger
/// position can be mapped to what's under it.
sealed class DragTag {
  const DragTag();
}

class FileTag extends DragTag {
  const FileTag(this.index);
  final int index;
}

class FolderTag extends DragTag {
  const FolderTag(this.name);
  final String name;
}

/// Wraps a tile/row so [SelectionGestures] can find it under the finger.
class Tagged extends StatelessWidget {
  const Tagged({super.key, required this.tag, required this.child});
  final DragTag tag;
  final Widget child;

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: tag,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}

enum _Mode { none, select, drag }

/// Gallery-style selection over a scrollable grid:
///
/// - Hold an unselected file: it gets selected; keep the finger down and
///   slide to select every file between it and where the finger is.
/// - Hold a selected file: a "N items" bubble follows the finger; let go on
///   a folder to move the selection there.
/// - Hold still (either way) and [onHoldMenu] opens the action menu.
/// - Near the top or bottom edge the list scrolls by itself.
class SelectionGestures extends StatefulWidget {
  const SelectionGestures({
    super.key,
    required this.scrollController,
    required this.fileNames,
    required this.selected,
    required this.onSelectionChanged,
    required this.onDropOnFolder,
    required this.onHoldMenu,
    required this.onFolderHold,
    required this.hoverFolder,
    required this.child,
  });

  final ScrollController scrollController;

  /// Names of the files in grid order (index = [FileTag.index]).
  final List<String> fileNames;
  final Set<String> selected;
  final ValueChanged<Set<String>> onSelectionChanged;
  final ValueChanged<String> onDropOnFolder;
  final VoidCallback onHoldMenu;

  /// Holding a folder row (not while dragging a selection).
  final ValueChanged<String> onFolderHold;

  /// Folder currently under the dragged bubble (for highlighting).
  final ValueNotifier<String?> hoverFolder;
  final Widget child;

  @override
  State<SelectionGestures> createState() => _SelectionGesturesState();
}

class _SelectionGesturesState extends State<SelectionGestures> {
  static const _holdStill = Duration(milliseconds: 700);
  static const _stillRadius = 16.0;
  static const _edge = 80.0;

  _Mode _mode = _Mode.none;
  int? _anchor;
  Set<String> _base = {};
  Offset _pointer = Offset.zero;
  Offset _stillAt = Offset.zero;
  Timer? _holdTimer;
  Timer? _autoScroll;
  double _scrollSpeed = 0;
  OverlayEntry? _bubble;

  @override
  void dispose() {
    _end();
    super.dispose();
  }

  DragTag? _tagAt(Offset global) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      global,
      View.of(context).viewId,
    );
    for (final e in result.path) {
      final t = e.target;
      if (t is RenderMetaData && t.metaData is DragTag) {
        return t.metaData as DragTag;
      }
    }
    return null;
  }

  void _start(LongPressStartDetails d) {
    _pointer = d.globalPosition;
    final tag = _tagAt(d.globalPosition);
    if (tag is FolderTag) {
      unawaited(HapticFeedback.selectionClick());
      widget.onFolderHold(tag.name);
      return;
    }
    if (tag is! FileTag || tag.index >= widget.fileNames.length) return;
    final name = widget.fileNames[tag.index];
    unawaited(HapticFeedback.selectionClick());
    if (widget.selected.contains(name)) {
      _mode = _Mode.drag;
      _showBubble();
    } else {
      _mode = _Mode.select;
      _anchor = tag.index;
      _base = {...widget.selected};
      widget.onSelectionChanged({..._base, name});
    }
    _restartHoldTimer(d.globalPosition);
  }

  void _move(LongPressMoveUpdateDetails d) {
    if (_mode == _Mode.none) return;
    _pointer = d.globalPosition;
    if ((d.globalPosition - _stillAt).distance > _stillRadius) {
      _restartHoldTimer(d.globalPosition);
    }
    _updateAt(d.globalPosition);
    _updateAutoScroll(d.globalPosition);
  }

  void _endGesture(LongPressEndDetails d) {
    final wasDrag = _mode == _Mode.drag;
    final target = widget.hoverFolder.value;
    _end();
    if (wasDrag && target != null) widget.onDropOnFolder(target);
  }

  void _end() {
    _mode = _Mode.none;
    _anchor = null;
    _holdTimer?.cancel();
    _autoScroll?.cancel();
    _autoScroll = null;
    _bubble?.remove();
    _bubble = null;
    widget.hoverFolder.value = null;
  }

  void _restartHoldTimer(Offset at) {
    _stillAt = at;
    _holdTimer?.cancel();
    _holdTimer = Timer(_holdStill, () {
      if (_mode == _Mode.none || !mounted) return;
      _end();
      unawaited(HapticFeedback.mediumImpact());
      widget.onHoldMenu();
    });
  }

  void _updateAt(Offset global) {
    final tag = _tagAt(global);
    switch (_mode) {
      case _Mode.select:
        if (tag is FileTag && tag.index < widget.fileNames.length) {
          final lo = min(_anchor!, tag.index);
          final hi = max(_anchor!, tag.index);
          widget.onSelectionChanged({
            ..._base,
            for (var i = lo; i <= hi; i++) widget.fileNames[i],
          });
        }
      case _Mode.drag:
        widget.hoverFolder.value = tag is FolderTag ? tag.name : null;
        _bubble?.markNeedsBuild();
      case _Mode.none:
        break;
    }
  }

  void _updateAutoScroll(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final y = box.globalToLocal(global).dy;
    final h = box.size.height;
    _scrollSpeed = y < _edge
        ? -(_edge - y) / _edge * 20
        : y > h - _edge
        ? (y - (h - _edge)) / _edge * 20
        : 0;
    if (_scrollSpeed == 0) {
      _autoScroll?.cancel();
      _autoScroll = null;
      return;
    }
    _autoScroll ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final c = widget.scrollController;
      if (!c.hasClients) return;
      final pos = c.position;
      final to = (pos.pixels + _scrollSpeed).clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      );
      if (to != pos.pixels) {
        c.jumpTo(to);
        _updateAt(_pointer);
      }
    });
  }

  void _showBubble() {
    _bubble = OverlayEntry(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        return Positioned(
          left: _pointer.dx - 48,
          top: _pointer.dy - 96,
          child: IgnorePointer(
            child: Material(
              elevation: 8,
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(24),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.drive_file_move_outline,
                      color: scheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${widget.selected.length} '
                      '${widget.selected.length == 1 ? 'item' : 'items'}',
                      style: TextStyle(color: scheme.onPrimaryContainer),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    Overlay.of(context).insert(_bubble!);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPressStart: _start,
    onLongPressMoveUpdate: _move,
    onLongPressEnd: _endGesture,
    onLongPressCancel: _end,
    child: widget.child,
  );
}
