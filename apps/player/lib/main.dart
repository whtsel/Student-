import 'package:flutter/material.dart';

import 'licence/licence_gate_screen.dart';

/// The users app entry point.
///
/// Routes:
///   * `/`        — the licence gate (device code + licence verification)
///
/// The course screen is pushed directly from the licence gate via a
/// [MaterialPageRoute] once a licence is verified, so it needs no named
/// route here.
void main() => runApp(const CoursePackPlayerApp());

class CoursePackPlayerApp extends StatelessWidget {
  const CoursePackPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CoursePack Player',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
        colorSchemeSeed: const Color(0xFF34D3B4),
      ),
      initialRoute: LicenceGateScreen.routeName,
      routes: <String, WidgetBuilder>{
        LicenceGateScreen.routeName: (BuildContext context) =>
            const LicenceGateScreen(),
      },
    );
  }
}
