import 'package:flutter/material.dart';

Color parseHexColor(String hex, Color defaultColor) {
  try {
    String clean = hex.replaceAll('#', '').trim();
    if (clean.length == 6) {
      clean = 'FF' + clean;
    }
    if (clean.length == 8) {
      return Color(int.parse(clean, radix: 16));
    }
  } catch (_) {}
  return defaultColor;
}

String colorToHex(Color color) {
  return '#' + color.value.toRadixString(16).padLeft(8, '0').toUpperCase();
}
