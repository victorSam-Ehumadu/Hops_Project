import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class FontPreviewScreen extends StatelessWidget {
  const FontPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('Font Previews', style: TextStyle(color: colors.primary)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: colors.primary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSetCard(
              label: 'Set A – Poppins + Nunito',
              headlineFont: GoogleFonts.poppins,
              bodyFont: GoogleFonts.nunito,
              colors: colors,
            ),
            const SizedBox(height: 24),
            _buildSetCard(
              label: 'Set B – Montserrat + Inter',
              headlineFont: GoogleFonts.montserrat,
              bodyFont: GoogleFonts.inter,
              colors: colors,
            ),
            const SizedBox(height: 24),
            _buildSetCard(
              label: 'Set C – Rubik + Roboto',
              headlineFont: GoogleFonts.rubik,
              bodyFont: GoogleFonts.roboto,
              colors: colors,
            ),
            const SizedBox(height: 24),
            _buildSetCard(
              label: 'Set D – Lato + Merriweather',
              headlineFont: GoogleFonts.lato,
              bodyFont: GoogleFonts.merriweather,
              colors: colors,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetCard({
    required String label,
    required TextStyle Function({TextStyle? textStyle}) headlineFont,
    required TextStyle Function({TextStyle? textStyle}) bodyFont,
    required ColorScheme colors,
  }) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
      color: colors.surface.withOpacity(0.6),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Heading Preview',
              style: headlineFont(textStyle: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87)),
            ),
            const SizedBox(height: 8),
            Text(
              'The quick brown fox jumps over the lazy dog.',
              style: bodyFont(textStyle: const TextStyle(fontSize: 16, color: Colors.black54)),
            ),
            const SizedBox(height: 4),
            Text(
              'ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz 0123456789',
              style: bodyFont(textStyle: const TextStyle(fontSize: 14, color: Colors.black45)),
            ),
            const SizedBox(height: 12),
            Text(
              'Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.',
              style: bodyFont(textStyle: const TextStyle(fontSize: 14, color: Colors.black87, height: 1.5)),
            ),
          ],
        ),
      ),
    );
  }
}