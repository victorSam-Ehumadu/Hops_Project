import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:client/models/feature_item.dart';
import 'package:client/theme/hops_theme.dart';

class HalfWheelPicker extends StatelessWidget {
  final List<FeatureItem> features;
  final void Function(FeatureItem) onSelected;

  const HalfWheelPicker({
    super.key,
    required this.features,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (features.isEmpty) return const SizedBox.shrink();

    final screenWidth = MediaQuery.of(context).size.width;
    final itemSize = 64.0;
    final spacing = 16.0;
    final viewportFraction = 0.25; // each item takes 25% of screen width

    return Container(
      height: 260,
      decoration: BoxDecoration(
        color: HopsTheme.background,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(32),
          topRight: Radius.circular(32),
        ),
        boxShadow: [
          BoxShadow(
            color: HopsTheme.primary.withOpacity(0.15),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Column(
        children: [
          // Grabber
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(100),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            "Quick Access",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
              color: HopsTheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: PageView.builder(
              controller: PageController(
                viewportFraction: viewportFraction,
              ),
              itemCount: features.length,
              itemBuilder: (context, index) {
                final feature = features[index];
                return GestureDetector(
                  onTap: () {
                    onSelected(feature);
                    Navigator.of(context).pop(); // close sheet
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: itemSize,
                        height: itemSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: HopsTheme.primary.withOpacity(0.2),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Icon(
                          feature.icon,
                          size: 30,
                          color: HopsTheme.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        feature.name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: HopsTheme.primary,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}