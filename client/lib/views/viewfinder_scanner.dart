import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class HopsActiveViewfinderScannerWorkspace extends StatefulWidget {
  final Function(String code) onCodeDetected;
  const HopsActiveViewfinderScannerWorkspace(
      {super.key, required this.onCodeDetected});
  @override
  State<HopsActiveViewfinderScannerWorkspace> createState() =>
      _HopsActiveViewfinderScannerWorkspaceState();
}

class _HopsActiveViewfinderScannerWorkspaceState
    extends State<HopsActiveViewfinderScannerWorkspace> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false; // guards against multiple detections firing per frame stream

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue?.trim().toUpperCase();
      if (raw == null || raw.isEmpty) continue;
      // Accept anything shaped like a Hops pairing code — the QR encodes
      // exactly what token_generator.dart renders (formattedCode).
      if (RegExp(r'^HPS-[A-Z0-9]{3}-[A-Z0-9]{3}$').hasMatch(raw)) {
        _handled = true;
        widget.onCodeDetected(raw);
        Navigator.pop(context);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Flexible(
          child: Text(
            "Scan Network Signature",
            style: TextStyle(color: Colors.white),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        backgroundColor: Colors.transparent,
        leading: const BackButton(color: Colors.white),
        actions: [
          // Reflect the controller's actual torch state instead of always
          // showing flash_on regardless of whether it's really on.
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, child) {
              final isOn = state.torchState == TorchState.on;
              return IconButton(
                icon: Icon(isOn ? Icons.flash_on : Icons.flash_off, color: Colors.white),
                onPressed: state.torchState == TorchState.unavailable
                    ? null
                    : () => _controller.toggleTorch(),
                tooltip: isOn ? 'Turn off flash' : 'Turn on flash',
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "Camera unavailable: ${error.errorDetails?.message ?? error.errorCode}",
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                  border: Border.all(color: colors.primary, width: 3),
                  borderRadius: BorderRadius.circular(24)),
              child: const Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text(
                      "Align peer's QR code within borders",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
