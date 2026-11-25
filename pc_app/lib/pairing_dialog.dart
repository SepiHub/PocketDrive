import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'server/devices.dart';

/// Shows the pairing QR code until a phone pairs (pops with the device) or
/// the code expires.
class PairingDialog extends StatefulWidget {
  const PairingDialog({
    super.key,
    required this.window,
    required this.qr,
    required this.paired,
  });

  final PairingWindow window;
  final PairingQr qr;
  final Stream<PairedDevice> paired;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  late final StreamSubscription<PairedDevice> _sub;
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _sub = widget.paired.listen((d) {
      if (mounted) Navigator.of(context).pop(d);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.window.expires.difference(DateTime.now());
    final open = widget.window.isOpen;
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Pair a phone'),
      scrollable: true,
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (open)
              Container(
                color: Colors.white, // QR codes need a light background
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: widget.qr.encode(), size: 260),
              )
            else
              const Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'This code has expired or was used up. '
                  'Close and try again.',
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Open PocketDrive on your phone and tap "Scan QR code".',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            if (open)
              Text(
                'Code expires in ${left.inMinutes}:'
                '${(left.inSeconds % 60).toString().padLeft(2, '0')}',
                style: theme.textTheme.bodySmall,
              ),
            Text(
              'PC addresses: ${widget.qr.hosts.join(', ')}',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
