import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'pc_client.dart';
import 'photo_viewer.dart';
import 'thumbnails.dart';
import 'video_page.dart';
import 'video_relay.dart';

String joinPath(String folder, String name) =>
    folder.isEmpty ? name : '$folder/$name';

/// One folder on the PC: subfolders as a list, files as a preview grid.
class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    required this.client,
    required this.thumbs,
    required this.relay,
    required this.path,
    this.onNotPaired,
    this.menu,
  });

  final PcClient client;
  final ThumbnailCache thumbs;
  final VideoRelay relay;

  /// Folder relative to the shared folder; '' is the top.
  final String path;
  final VoidCallback? onNotPaired;

  /// Extra app-bar menu (only on the top folder).
  final Widget? menu;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  Listing? _listing;
  String? _error;
  bool _notPaired = false;
  bool _loading = true;

  String get _title => widget.path.isEmpty
      ? widget.client.pairing.pcName
      : widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = _listing == null;
      _error = null;
    });
    try {
      final listing = await widget.client.list(widget.path);
      _listing = listing;
    } on NotPaired {
      _notPaired = true;
      _error = '${widget.client.pairing.pcName} no longer accepts this phone '
          '(it was removed on the PC). Pair again.';
    } on PcUnreachable {
      _error = "Can't reach ${widget.client.pairing.pcName}. Is it on, is "
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
    if (e.isDir) {
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => BrowserPage(
          client: widget.client,
          thumbs: widget.thumbs,
          relay: widget.relay,
          path: path,
          onNotPaired: widget.onNotPaired,
        ),
      )));
      return;
    }
    if (e.kind == MediaKind.image) {
      final photos = [for (final f in files) if (f.kind == MediaKind.image) f];
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PhotoViewer(
          thumbs: widget.thumbs,
          folder: widget.path,
          photos: photos,
          initialIndex: photos.indexOf(e),
        ),
      )));
      return;
    }
    if (e.kind == MediaKind.video) {
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => VideoPage(
          relay: widget.relay,
          preview: PcImage(widget.thumbs, path, e, 256),
          path: path,
          entry: e,
        ),
      )));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text("Can't open this kind of file yet."),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
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
    );
  }

  Widget _content(Listing listing) {
    final folders = [for (final e in listing.entries) if (e.isDir) e];
    final files = [for (final e in listing.entries) if (!e.isDir) e];
    if (listing.entries.isEmpty) {
      return ListView(children: const [
        Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: Text('This folder is empty.')),
        ),
      ]);
    }
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverList.builder(
          itemCount: folders.length,
          itemBuilder: (context, i) => ListTile(
            leading: const Icon(Icons.folder),
            title: Text(folders[i].name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(folders[i], files),
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
            itemBuilder: (context, i) => _FileTile(
              entry: files[i],
              image: PcImage(widget.thumbs, joinPath(widget.path, files[i].name),
                  files[i], 256),
              onTap: () => _open(files[i], files),
            ),
          ),
        ),
      ],
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.entry,
    required this.image,
    required this.onTap,
  });

  final RemoteEntry entry;
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
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : child,
                errorBuilder: (context, error, stack) => fallback,
              ),
            if (entry.kind == MediaKind.video)
              const Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 36),
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
          Icon(
            switch (entry.kind) {
              MediaKind.image => Icons.image_outlined,
              MediaKind.video => Icons.movie_outlined,
              MediaKind.other => Icons.insert_drive_file_outlined,
            },
            size: 32,
          ),
          const SizedBox(height: 4),
          Text(entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall),
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
