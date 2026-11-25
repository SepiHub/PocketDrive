import 'dart:async';

import 'package:file_picker/file_picker.dart' as files;
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'app_settings.dart';
import 'discovery.dart';
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
  AppSettings get _settings => widget.session.settings;
  bool _notPaired = false;
  bool _unreachable = false;
  bool _searching = false;
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
    _settings.addListener(_resort);
    // Show new uploads here as soon as they land.
    // Also when it lands in a direct subfolder: that folder's file count,
    // shown here, changed.
    _uploadSub = _uploads.folderChanged.listen((folder) {
      final slash = folder.lastIndexOf('/');
      final parent = folder.isEmpty
          ? null
          : (slash < 0 ? '' : folder.substring(0, slash));
      if ((folder == widget.path || parent == widget.path) && mounted) {
        unawaited(_load());
      }
    });
  }

  @override
  void dispose() {
    unawaited(_uploadSub?.cancel());
    _settings.removeListener(_resort);
    _scroll.dispose();
    _hoverFolder.dispose();
    super.dispose();
  }

  /// Folders first, then files; each group by the chosen order (folders
  /// have no size, so "size" sorts them by name).
  List<RemoteEntry> _sorted(List<RemoteEntry> entries) {
    final by = _settings.sortBy;
    final desc = _settings.sortDescending;
    int byName(RemoteEntry a, RemoteEntry b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase());
    int compare(RemoteEntry a, RemoteEntry b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      final c = switch (by) {
        SortBy.name => byName(a, b),
        SortBy.date => a.modified.compareTo(b.modified),
        SortBy.size => a.isDir ? byName(a, b) : a.size.compareTo(b.size),
      };
      final tie = c == 0 ? byName(a, b) : c;
      return desc ? -tie : tie;
    }

    return [...entries]..sort(compare);
  }

  bool _listedHidden = false;

  void _resort() {
    // Turning "Show hidden folders" on/off needs a fresh list from the PC.
    if (_settings.showHidden != _listedHidden) {
      _listedHidden = _settings.showHidden;
      unawaited(_load());
      return;
    }
    final l = _listing;
    if (l == null || !mounted) return;
    setState(
      () => _listing = Listing(path: l.path, entries: _sorted(l.entries)),
    );
  }

  Widget _sortMenu() {
    final by = _settings.sortBy;
    final desc = _settings.sortDescending;
    return PopupMenuButton<String>(
      tooltip: 'Sort and view',
      icon: const Icon(Icons.sort),
      onSelected: (v) {
        switch (v) {
          case 'asc':
            unawaited(_settings.setSort(by, descending: false));
          case 'hidden':
            _settings.showHidden = !_settings.showHidden;
          case 'desc':
            unawaited(_settings.setSort(by, descending: true));
          default:
            final next = SortBy.values.byName(v);
            // Dates and sizes are most useful newest/biggest first.
            unawaited(
              _settings.setSort(
                next,
                descending: next == by ? desc : next != SortBy.name,
              ),
            );
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: SortBy.name.name,
          checked: by == SortBy.name,
          child: const Text('Name'),
        ),
        CheckedPopupMenuItem(
          value: SortBy.date.name,
          checked: by == SortBy.date,
          child: const Text('Date'),
        ),
        CheckedPopupMenuItem(
          value: SortBy.size.name,
          checked: by == SortBy.size,
          child: const Text('Size'),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'hidden',
          checked: _settings.showHidden,
          child: const Text('Show hidden folders'),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'asc',
          checked: !desc,
          child: Text(switch (by) {
            SortBy.name => 'A to Z',
            SortBy.date => 'Oldest first',
            SortBy.size => 'Smallest first',
          }),
        ),
        CheckedPopupMenuItem(
          value: 'desc',
          checked: desc,
          child: Text(switch (by) {
            SortBy.name => 'Z to A',
            SortBy.date => 'Newest first',
            SortBy.size => 'Largest first',
          }),
        ),
      ],
    );
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
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete…'),
              onTap: () => Navigator.pop(context, 'delete'),
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
      case 'delete':
        await _deleteSelected();
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

  /// Sends the selection to the PC's Recycle Bin, after asking.
  /// Holding a folder: hide it from the list, or show it again.
  Future<void> _folderMenu(String name) async {
    if (_selecting) return;
    final folder = _listing?.entries
        .where((e) => e.isDir && e.name == name)
        .firstOrNull;
    if (folder == null) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder),
              title: Text(name, style: Theme.of(context).textTheme.titleMedium),
            ),
            if (folder.hidden)
              ListTile(
                leading: const Icon(Icons.visibility),
                title: const Text('Unhide folder'),
                onTap: () => Navigator.pop(context, 'unhide'),
              )
            else
              ListTile(
                leading: const Icon(Icons.visibility_off),
                title: const Text('Hide folder'),
                subtitle: const Text(
                  'Tidies it away in this app. It stays a normal folder on '
                  'the PC.',
                ),
                onTap: () => Navigator.pop(context, 'hide'),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _client.setHidden(joinPath(widget.path, name), action == 'hide');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            action == 'hide'
                ? '"$name" is hidden. To see it again: sort menu > '
                      'Show hidden folders.'
                : '"$name" is visible again.',
          ),
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not change it: $e')),
      );
    }
    await _load();
  }

  Future<void> _deleteSelected() async {
    final names = _selected.toList();
    if (names.isEmpty) return;
    final n = names.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text('Delete $n ${n == 1 ? 'item' : 'items'}?'),
        content: const Text(
          'They go to the Recycle Bin on your PC, where you can still '
          'restore them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(ok ?? false) || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final (deleted, failed) = await _client.delete([
        for (final name in names) joinPath(widget.path, name),
      ]);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failed.isEmpty
                ? 'Moved $deleted ${deleted == 1 ? 'item' : 'items'} to the '
                      "PC's Recycle Bin"
                : 'Deleted $deleted, ${failed.length} could not be deleted',
          ),
        ),
      );
    } on Object catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
    _uploads.notifyFolderChanged(widget.path);
    _clearSelection();
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

  /// Upload: the gallery (Android limits it to about 100 per pick) or the
  /// Files app (no limit: open a folder like DCIM/Camera and Select all).
  Future<void> _upload() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('From gallery'),
              subtitle: const Text('Up to 100 at a time (an Android limit)'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('From files'),
              subtitle: const Text(
                'No limit. Open a folder (e.g. DCIM > Camera), then '
                '\u22ee > Select all',
              ),
              onTap: () => Navigator.pop(context, 'files'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    final List<XFile> picked;
    if (source == 'gallery') {
      picked = await ImagePicker().pickMultipleMedia();
    } else {
      final messenger = ScaffoldMessenger.of(context);
      final result = await files.FilePicker.pickFiles(
        onFileLoading: (status) {
          // Android copies the chosen files first; with hundreds that
          // takes a moment.
          if (status == files.FilePickerStatus.picking) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text('Preparing the selected files…'),
                duration: Duration(minutes: 5),
              ),
            );
          } else {
            messenger.hideCurrentSnackBar();
          }
        },
      );
      picked = [for (final f in result) f.xFile];
    }
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

  /// Searches the Wi-Fi for the PC's (new) address, then reloads.
  Future<void> _findPc() async {
    setState(() => _searching = true);
    final found = await discoverPcAddresses(_client.pairing.pcId);
    if (!mounted) return;
    setState(() => _searching = false);
    if (found.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Didn't find your PC on this Wi-Fi. Is it on, with "
            'PocketDrive running, and is the phone on the same network?',
          ),
        ),
      );
      return;
    }
    for (final h in found) {
      if (!_client.pairing.hosts.contains(h)) _client.pairing.hosts.add(h);
    }
    _client.forgetHost();
    await _load();
  }

  Future<void> _confirmPairAgain() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pair again?'),
        content: const Text(
          'This phone forgets the PC and opens the scanner. On the PC, click '
          '"Pair a phone" and scan the code. Your folders and files on the '
          'PC are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Pair again'),
          ),
        ],
      ),
    );
    if (ok ?? false) widget.onNotPaired?.call();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _listing == null;
      _error = null;
      _unreachable = false;
    });
    try {
      _listedHidden = _settings.showHidden;
      final listing = await _client.list(
        widget.path,
        showHidden: _listedHidden,
      );
      _listing = Listing(path: listing.path, entries: _sorted(listing.entries));
    } on NotPaired {
      _notPaired = true;
      _error =
          '${_client.pairing.pcName} no longer accepts this phone '
          '(it was removed on the PC). Pair again.';
    } on PcUnreachable {
      _unreachable = true;
      _listing = null; // stale: show the explanation instead
      _error =
          "Can't reach ${_client.pairing.pcName}.\n\n"
          'It may be turned off or asleep, or PocketDrive isn\'t running on '
          'it. Its address may also have changed.\n\n'
          '• Try again once the PC is on and PocketDrive is open.\n'
          '• Find my PC searches this Wi-Fi for its new address.\n'
          '• If that doesn\'t work, pair again: on the PC, click "Pair a '
          'phone" and scan the code. Your folders and files stay as they '
          'are.';
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
                client: _client,
                subtitleFiles: [
                  for (final f in files)
                    if (isSubtitleFile(f.name)) f.name,
                ],
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
                    tooltip: 'Delete',
                    onPressed: _deleteSelected,
                    icon: const Icon(Icons.delete_outline),
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
                  IconButton(
                    tooltip: 'Upload from gallery',
                    onPressed: listing == null ? null : _upload,
                    icon: const Icon(Icons.upload),
                  ),
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
                  // Refresh: pull down on the list.
                  _sortMenu(),
                  if (widget.menu != null) widget.menu!,
                ],
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && listing == null
            ? _unreachable
                  ? _ErrorView(
                      message: _error!,
                      actionLabel: 'Try again',
                      onAction: _load,
                      extra: [
                        OutlinedButton.icon(
                          onPressed: _searching ? null : _findPc,
                          icon: const Icon(Icons.wifi_find),
                          label: Text(_searching ? 'Searching…' : 'Find my PC'),
                        ),
                        TextButton(
                          onPressed: _confirmPairAgain,
                          child: const Text('Pair again'),
                        ),
                      ],
                    )
                  : _ErrorView(
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
      onFolderHold: (name) => unawaited(_folderMenu(name)),
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
                  title: Opacity(
                    opacity: folders[i].hidden ? 0.5 : 1,
                    child: Row(
                      children: [
                        Flexible(child: FolderName(folders[i])),
                        if (folders[i].hidden)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(Icons.visibility_off, size: 16),
                          ),
                      ],
                    ),
                  ),
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
    this.extra = const [],
  });

  final String message;
  final String actionLabel;
  final VoidCallback? onAction;
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(message, style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 16),
        FilledButton(onPressed: onAction, child: Text(actionLabel)),
        for (final w in extra) ...[const SizedBox(height: 8), w],
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
