import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pocketdrive_shared/pocketdrive_shared.dart';

/// Camera view that pops with the first PocketDrive pairing QR it sees.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final _controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;
  bool _sawOtherCode = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final qr = PairingQr.tryDecode(b.rawValue ?? '');
      if (qr != null) {
        _done = true;
        Navigator.of(context).pop(qr);
        return;
      }
    }
    if (!_sawOtherCode) setState(() => _sawOtherCode = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan the code on your PC')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  error.errorCode == MobileScannerErrorCode.permissionDenied
                      ? 'PocketDrive needs the camera to scan the pairing '
                          'code. Allow it in Settings > Apps > PocketDrive > '
                          'Permissions > Camera.'
                      : 'Camera problem: ${error.errorCode.name}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          if (_sawOtherCode)
            const Align(
              alignment: Alignment.bottomCenter,
              child: Card(
                margin: EdgeInsets.all(24),
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('That isn\'t a PocketDrive code. On your PC, '
                      'click "Pair a phone" and scan the code it shows.'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
