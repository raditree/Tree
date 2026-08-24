import 'package:flutter/material.dart';

void main() {
  final ThemeData light = ThemeData(
    primaryColor: const Color(0xFF00904A),
    colorScheme: const ColorScheme.light(
      primary: Color(0xFF00904A),
      onPrimary: Colors.white,
      secondary: Color(0xFF00904A),
      onSecondary: Colors.white,
      primaryContainer: Color(0xFFD9F2E3),
      onPrimaryContainer: Color(0xFF00491F),
      secondaryContainer: Color(0xFFD9F2E3),
      onSecondaryContainer: Color(0xFF00491F),
      surface: Colors.white,
      onSurface: Color(0xFF1A2E21),
    ),
    useMaterial3: false,
  );
  print('LIGHT outline=${light.colorScheme.outline}');
  print('LIGHT onSurfaceVariant=${light.colorScheme.onSurfaceVariant}');
  print('LIGHT surfaceVariant=${light.colorScheme.surfaceVariant}');

  final ThemeData dark = ThemeData(
    brightness: Brightness.dark,
    primaryColor: const Color(0xFF00FF8C),
    colorScheme: const ColorScheme.dark(
      primary: Color(0xFF00FF8C),
      onPrimary: Color(0xFF00280F),
      secondary: Color(0xFF00FF8C),
      onSecondary: Color(0xFF00280F),
      primaryContainer: Color(0xFF0E2B1A),
      onPrimaryContainer: Color(0xFFB8FFD9),
      secondaryContainer: Color(0xFF0E2B1A),
      onSecondaryContainer: Color(0xFFB8FFD9),
      surface: Color(0xFF030705),
      onSurface: Color(0xFFE6F3EC),
    ),
    useMaterial3: false,
  );
  print('DARK outline=${dark.colorScheme.outline}');
  print('DARK onSurfaceVariant=${dark.colorScheme.onSurfaceVariant}');
  print('DARK surfaceVariant=${dark.colorScheme.surfaceVariant}');
}
