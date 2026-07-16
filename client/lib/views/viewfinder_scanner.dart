import 'dart:math';
import 'package:flutter/material.dart';
import 'package:client/theme/hops_theme.dart';

class HopsActiveViewfinderScannerWorkspace extends StatefulWidget {
  final Function(String code) onCodeDetected;
  const HopsActiveViewfinderScannerWorkspace({super.key, required this.onCodeDetected});
  @override
  State<HopsActiveViewfinderScannerWorkspace> createState() => _HopsActiveViewfinderScannerWorkspaceState();
}

class _HopsActiveViewfinderScannerWorkspaceState extends State<HopsActiveViewfinderScannerWorkspace> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Scan Network Signature", style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.transparent,
        leading: const BackButton(color: Colors.white),
      ),
      body: Stack(
        children: [
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(border: Border.all(color: HopsTheme.primary, width: 3), borderRadius: BorderRadius.circular(24)),
              child: const Center(
                child: Text("Align peer token code within borders", textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 12)),
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
                label: const Text("Capture Nearby Node Token", style: TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(backgroundColor: HopsTheme.primary, foregroundColor: Colors.white),
                onPressed: () async {
                  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
                  String code = List.generate(6, (i) => chars[Random().nextInt(chars.length)]).join();
                  Navigator.pop(context);
                  widget.onCodeDetected("HPS-${code.substring(0,3)}-${code.substring(3,6)}");
                },
              ),
            ),
          )
        ],
      ),
    );
  }
}