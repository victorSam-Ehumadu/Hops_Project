import 'dart:math';
import 'package:flutter/material.dart';
import 'package:client/theme/hops_theme.dart';

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
  @override
  Widget build(BuildContext context) {
  final theme = Theme.of(context);      // ← here
  final colors = theme.colorScheme;     // ← here
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
      ),
      body: Stack(
        children: [
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                  borderRadius: BorderRadius.circular(24)),
              child: const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                    "Align peer token code within borders",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 64,
            left: 24,
            right: 24,
            child: SizedBox(
              height: 50,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.qr_code_scanner),
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    "Capture Nearby Node Token",
                    style: TextStyle(fontWeight: FontWeight.bold),
                    maxLines: 1,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white),
                onPressed: () async {
                  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
                  String code = List.generate(
                      6, (i) => chars[Random().nextInt(chars.length)]).join();
                  Navigator.pop(context);
                  widget.onCodeDetected(
                      "HPS-${code.substring(0, 3)}-${code.substring(3, 6)}");
                },
              ),
            ),
          )
        ],
      ),
    );
  }
}