import 'package:flutter/services.dart';
import 'dart:math';

class HopIdInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    String text = newValue.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (!text.startsWith('HPS')) {
      text = 'HPS${text.replaceAll('HPS', '')}';
    }
    String cleanPayload = text.substring(min(3, text.length));
    String formatted = 'HPS';

    if (cleanPayload.isNotEmpty) {
      formatted += '-';
      formatted += cleanPayload.substring(0, min(3, cleanPayload.length));
    }
    if (cleanPayload.length > 3) {
      formatted += '-';
      formatted += cleanPayload.substring(3, min(6, cleanPayload.length));
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}