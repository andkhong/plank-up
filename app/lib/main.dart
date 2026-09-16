import 'package:flutter/material.dart';

import 'demo/session_demo.dart';
import 'theme/solar_dusk.dart';

void main() => runApp(const PlankUpApp());

class PlankUpApp extends StatelessWidget {
  const PlankUpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plank Up',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: SolarDuskDark.background,
        colorScheme: const ColorScheme.dark(
          primary: SolarDuskDark.primary,
          surface: SolarDuskDark.card,
          onSurface: SolarDuskDark.foreground,
        ),
      ),
      home: const SessionDemo(),
    );
  }
}
