import 'dart:async';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'folder_picker.dart';
import 'pc_client.dart';
import 'photo_viewer.dart';
import 'selection.dart';
import 'session.dart';
import 'slideshow_page.dart';
import 'thumbnails.dart';
import 'upload_queue.dart';
import 'video_page.dart';

String joinPath(String folder, String name) =>
    folder.isEmpty ? name : '$folder/$name';

/// One folder on the PC: subfolders as a list, files as a preview grid.
class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    required this.session,
    required this.path,
    this.onNotPaired,
    this.menu,
  });

  final PcSession session;

  /// Folder relative to the shared folder; '' is the top.
  final String path;
  final VoidCallback? onNotPaired;

  /// Extra app-bar menu (only on the top folder).
  final Widget? menu;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  PcClient get _client => widget.session.client;
  ThumbnailCache get _thumbs => widget.session.thumbs;
  UploadQueue get _uploads => widget.session.uploads;
  StreamSubscription<String>? _uploadSub;
  Listing? _listing;
  String? _error;
  bool _notPaired = false;
  bool _loading = true;

  /// Selected file names (folders can't be selected; they're drop targets).
  Set<String> _selected = {};
  final _scroll = ScrollController();
  final _hoverFolder = ValueNotifier<String?>(null);

  bool get _selecting => _selected.isNotEmpty;

  String get _title => widget.path.isEmpty
      ? _client.pairing.pcName
      : widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // Show new uploads here as soon as they land.
    _uploadSub = _uploads.folderChanged.listen((folder) {
      if (folder == widget.path && mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    unawaited(_uploadSub?.cancel());
    _scroll.dispose();
    _hoverFolder.dispose();
    super.dispose();
  }

  List<RemoteEntry> get _files => [
    for (final e in _listing?.entries ?? const <RemoteEntry>[])
      if (!e.isDir) e,
  ];

  void _clearSelection() => setState(() => _selected = {});

  void _selectAll() =>
      setState(() => _selected = {for (final f in _files) f.name});

  void _toggle(String name) => setState(() {
    _selected = {..._selected};
    if (!_selected.remove(name)) _selected.add(name);
  });

  Future<void> _showSelectionMenu() async {
    if (!_selecting) return;
    final n = _selected.length;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '$n ${n == 1 ? 'item' : 'items'} selected',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move to folder…'),
              onTap: () => Navigator.pop(context, 'move'),
            ),
            ListTile(
              leading: const Icon(Icons.select_all),
              title: const Text('Select all'),
              onTap: () => Navigator.pop(context, 'all'),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Clear selection'),
              onTap: () => Navigator.pop(context, 'clear'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'move':
        await _moveToPicker();
      case 'all':
        _selectAll();
      case 'clear':
        _clearSelection();
    }
  }

  Future<void> _moveToPicker() async {
    final dest = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FolderPickerPage(
          client: _client,
          start: widget.path,
          actionLabel: 'Move to',
          disabled: {widget.path},
        ),
      ),
    );
    if (dest != null) await _moveSelected(dest);
  }

  Future<void> _moveSelected(String dest) async {
    final names = _selected.toList();
    if (names.isEmpty || dest == widget.path) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final (moved, failed) = await _client.move([
        for (final n in names) joinPath(widget.path, n),
      ], dest);
      final where = dest.isEmpty ? _client.pairing.pcName : dest;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failed.isEmpty
                ? 'Moved $moved ${moved == 1 ? 'item' : 'items'} to "$where"'
                : 'Moved $moved, ${failed.length} could not be moved',
          ),
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Move failed: $e')));
    }
    _uploads
      ..notifyFolderChanged(dest)
      ..notifyFolderChanged(widget.path);
    _clearSelection();
  }

  Future<void> _upload() async {
    final picked = await ImagePicker().pickMultipleMedia();
    if (picked.isEmpty) return;
    await _uploads.add(widget.path, picked);
  }

  Future<void> _newFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewFolderDialog(),
    );
    if (name == null || !mounted) return;
    try {
      await _client.mkdir(widget.path, name);
      await _load();
    } on PcError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e.code == ApiError.exists
                ? 'There is already something called "$name" here.'
                : "Couldn't create the folder (${e.code}).",
          ),
        ),
      );
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Couldn't create the folder: $e")));
    }
  }

  void _slideshow(List<RemoteEntry> media) {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SlideshowPage(
            thumbs: _thumbs,
            relay: widget.session.relay,
            settings: widget.session.settings,
            folder: widget.path,
            items: media,
          ),
        ),
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = _listing == null;
      _error = null;
    });
    try {
      final listing = await _client.list(widget.path);
      _listing = listing;
    } on NotPaired {
      _notPaired = true;
      _error =
          '${_client.pairing.pcName} no longer accepts this phone '
          '(it was removed on the PC). Pair again.';
    } on PcUnreachable {
      _error =
          "Can't reach ${_client.pairing.pcName}. Is it on, is "
          'PocketDrive running there, and is the phone on the same Wi-Fi?';
    } on PcError catch (e) {
      _error = e.code == ApiError.notFound
          ? 'This folder no longer exists on the PC.'
          : 'The PC said: ${e.code}';
    } on Object catch (e) {
      _error = 'Something went wrong: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  void _open(RemoteEntry e, List<RemoteEntry> files) {
    final path = joinPath(widget.path, e.name);
    if (_selecting && !e.isDir) {
      _toggle(e.name);
      return;
    }
    if (e.isDir) {
      _clearSelection();
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BrowserPage(
              session: widget.session,
              path: path,
              onNotPaired: widget.onNotPaired,
            ),
          ),
        ),
      );
      return;
    }
    if (e.kind == MediaKind.image) {
      final photos = [
        for (final f in files)
          if (f.kind == MediaKind.image) f,
      ];
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PhotoViewer(
              thumbs: _thumbs,
              folder: widget.path,
              photos: photos,
              initialIndex: photos.indexOf(e),
            ),
          ),
        ),
      );
      return;
    }
    if (e.kind == MediaKind.video) {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) {
              final videos = [
                for (final f in files)
                  if (f.kind == MediaKind.video) f,
              ];
              return VideoPage(
                settings: widget.session.settings,
                relay: widget.session.relay,
                thumbs: _thumbs,
                folder: widget.path,
                videos: videos,
                initialIndex: videos.indexOf(e),
              );
            },
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Can't open this kind of file yet.")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final media = [
      for (final e in listing?.entries ?? const <RemoteEntry>[])
        if (e.kind != MediaKind.other) e,
    ];
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        floatingActionButton: listing == null || _selecting
            ? null
            : FloatingActionButton.extended(
                onPressed: _upload,
                icon: const Icon(Icons.upload),
                label: const Text('Upload'),
              ),
        bottomNavigationBar: UploadBanner(queue: _uploads),
        appBar: _selecting
            ? AppBar(
                leading: IconButton(
                  tooltip: 'Clear selection',
                  onPressed: _clearSelection,
                  icon: const Icon(Icons.close),
                ),
                title: Text('${_selected.length} selected'),
                actions: [
                  IconButton(
                    tooltip: 'Select all',
                    onPressed: _selectAll,
                    icon: const Icon(Icons.select_all),
                  ),
                  IconButton(
                    tooltip: 'Move to folder',
                    onPressed: _moveToPicker,
                    icon: const Icon(Icons.drive_file_move_outline),
                  ),
                  IconButton(
                    tooltip: 'More',
                    onPressed: _showSelectionMenu,
                    icon: const Icon(Icons.more_vert),
                  ),
                ],
              )
            : AppBar(
                title: Text(_title),
                actions: [
                  if (media.isNotEmpty)
                    IconButton(
                      tooltip: 'Slideshow',
                      onPressed: () => _slideshow(media),
                      icon: const Icon(Icons.slideshow),
                    ),
                  IconButton(
                    tooltip: 'New folder',
                    onPressed: listing == null ? null : _newFolder,
                    icon: const Icon(Icons.create_new_folder_outlined),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh),
                  ),
                  if (widget.menu != null) widget.menu!,
                ],
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && listing == null
            ? _ErrorView(
                message: _error!,
                actionLabel: _notPaired ? 'Pair again' : 'Try again',
                onAction: _notPaired ? widget.onNotPaired : _load,
              )
            : RefreshIndicator(onRefresh: _load, child: _content(listing!)),
      ),
    );
  }

  Widget _content(Listing listing) {
    final folders = [
      for (final e in listing.entries)
        if (e.isDir) e,
    ];
    final files = [
      for (final e in listing.entries)
        if (!e.isDir) e,
    ];
    if (listing.entries.isEmpty) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(48),
            child: Center(child: Text('This folder is empty.')),
          ),
        ],
      );
    }
    return SelectionGestures(
      scrollController: _scroll,
      fileNames: [for (final f in files) f.name],
      selected: _selected,
      onSelectionChanged: (s) => setState(() => _selected = s),
      onDropOnFolder: (name) =>
          unawaited(_moveSelected(joinPath(widget.path, name))),
      onHoldMenu: () => unawaited(_showSelectionMenu()),
      hoverFolder: _hoverFolder,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverList.builder(
            itemCount: folders.length,
            itemBuilder: (context, i) => Tagged(
              tag: FolderTag(folders[i].name),
              child: ValueListenableBuilder(
                valueListenable: _hoverFolder,
                builder: (context, hover, _) => ListTile(
                  tileColor: hover == folders[i].name
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  leading: Icon(
                    hover == folders[i].name ? Icons.folder_open : Icons.folder,
                  ),
                  title: FolderName(folders[i]),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(folders[i], files),
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(2),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: files.length,
              itemBuilder: (context, i) => Tagged(
                tag: FileTag(i),
                child: _FileTile(
                  entry: files[i],
                  selecting: _selecting,
                  selected: _selected.contains(files[i].name),
                  image: PcImage(
                    _thumbs,
                    joinPath(widget.path, files[i].name),
                    files[i],
                    256,
                  ),
                  onTap: () => _open(files[i], files),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.entry,
    required this.selecting,
    required this.selected,
    required this.image,
    required this.onTap,
  });

  final RemoteEntry entry;
  final bool selecting;
  final bool selected;
  final PcImage image;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = _NamedIcon(entry: entry);
    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (entry.kind == MediaKind.other)
              fallback
            else
              Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, sync) => frame == null
                    ? const Center(
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : child,
                errorBuilder: (context, error, stack) => fallback,
              ),
            if (isGif(entry.name))
              const Positioned(right: 4, bottom: 4, child: _Badge('GIF')),
            if (entry.kind == MediaKind.video)
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  color: Colors.white70,
                  size: 36,
                ),
              ),
            if (selected)
              ColoredBox(color: scheme.primary.withValues(alpha: 0.30)),
            if (selecting)
              Positioned(
                left: 4,
                top: 4,
                child: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? scheme.primary : Colors.white,
                  shadows: const [Shadow(blurRadius: 3)],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NamedIcon extends StatelessWidget {
  const _NamedIcon({required this.entry});
  final RemoteEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(switch (entry.kind) {
            MediaKind.image => Icons.image_outlined,
            MediaKind.video => Icons.movie_outlined,
            MediaKind.other => Icons.insert_drive_file_outlined,
          }, size: 32),
          const SizedBox(height: 4),
          Text(
            entry.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(message, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 16),
        FilledButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 10,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final _name = TextEditingController();
  String? _problem;

  /// Same rules the PC enforces, so the user sees the reason right away.
  static String? _check(String n) {
    if (n.isEmpty) return null;
    if (n == '.' || n == '..') return 'Not a valid name.';
    if (RegExp(r'[<>:"/\\|?*]').hasMatch(n)) {
      return 'Names can\'t contain < > : " / \\ | ? *';
    }
    if (n.startsWith('.')) return "Names can't start with a dot.";
    if (n.endsWith('.') || n.endsWith(' ')) {
      return "Names can't end with a dot or space.";
    }
    return null;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final n = _name.text.trim();
    if (n.isEmpty || _check(n) != null) return;
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New folder'),
      content: TextField(
        controller: _name,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: 'Folder name',
          errorText: _problem,
        ),
        onChanged: (v) => setState(() => _problem = _check(v.trim())),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
