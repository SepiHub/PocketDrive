import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

import 'pc_client.dart';

/// A folder's name followed by its number of files in a smaller, lighter
/// font, e.g. "Holiday 2024  12".
class FolderName extends StatelessWidget {
  const FolderName(this.folder, {super.key});
  final RemoteEntry folder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = folder.fileCount;
    return Text.rich(
      TextSpan(
        text: folder.name,
        children: [
          if (count != null)
            TextSpan(
              text: '  $count',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Lets the user pick a destination folder on the PC. Starts in [start],
/// can go up and into folders, and create a new one. Pops with the chosen
/// folder's path ('' = the top of the shared folder).
class FolderPickerPage extends StatefulWidget {
  const FolderPickerPage({
    super.key,
    required this.client,
    required this.start,
    required this.actionLabel,
    this.disabled = const {},
  });

  final PcClient client;
  final String start;
  final String actionLabel;

  /// Folders that can't be chosen or entered (e.g. ones being moved).
  final Set<String> disabled;

  @override
  State<FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends State<FolderPickerPage> {
  late String _path = widget.start;
  List<RemoteEntry>? _folders;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String _join(String name) => _path.isEmpty ? name : '$_path/$name';

  Future<void> _load() async {
    setState(() {
      _folders = null;
      _error = null;
    });
    try {
      final listing = await widget.client.list(_path);
      if (!mounted) return;
      setState(
        () => _folders = [
          for (final e in listing.entries)
            if (e.isDir) e,
        ],
      );
    } on Object catch (e) {
      if (mounted) setState(() => _error = 'Could not load folders: $e');
    }
  }

  void _open(String path) {
    _path = path;
    unawaited(_load());
  }

  void _up() {
    final i = _path.lastIndexOf('/');
    _open(i < 0 ? '' : _path.substring(0, i));
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    try {
      await widget.client.mkdir(_path, name);
      _open(_join(name));
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is PcError && e.code == ApiError.exists
                ? 'There is already something called "$name" here.'
                : "Couldn't create the folder.",
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    final title = _path.isEmpty ? widget.client.pairing.pcName : _path;
    final canChoose = !widget.disabled.contains(_path);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose a folder'),
            Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'New folder',
            onPressed: _newFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : folders == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (_path.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.arrow_upward),
                    title: const Text('Up one level'),
                    onTap: _up,
                  ),
                if (folders.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('No folders here.'),
                  ),
                for (final f in folders)
                  ListTile(
                    enabled: !widget.disabled.contains(_join(f.name)),
                    leading: const Icon(Icons.folder),
                    title: FolderName(f),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(_join(f.name)),
                  ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(
            onPressed: canChoose ? () => Navigator.pop(context, _path) : null,
            icon: const Icon(Icons.drive_file_move_outline),
            label: Text('${widget.actionLabel} "$title"'),
          ),
        ),
      ),
    );
  }
}
