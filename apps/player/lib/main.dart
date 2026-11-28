import 'package:flutter/material.dart';

import 'licence/licence_gate_screen.dart';
import 'player/course_screen.dart';

/// The users app entry point.
///
/// Routes:
///   * `/`        — the licence gate (device code + licence verification)
///   * `/course`  — the course screen (lecture list + encrypted playback)
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
        CourseScreen.routeName: (BuildContext context) {
          final payload =
              ModalRoute<void>.of(context)!.settings.arguments as Map;
          return CourseScreen(payload: payload);
        },
      },
    );
  }
}
