import 'package:flutter/material.dart';

import 'licenser/licenser_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CoursePackApp());
}

class CoursePackApp extends StatelessWidget {
  const CoursePackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CoursePack Licence Generator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF245B9E)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0B0D12),
      ),
      home: const LicenserScreen(),
    );
  }
}
