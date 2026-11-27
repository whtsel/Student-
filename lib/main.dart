import 'package:flutter/material.dart';

void main() {
  runApp(const CoursePackApp());
}

class CoursePackApp extends StatelessWidget {
  const CoursePackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CoursePack',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF245B9E)),
        useMaterial3: true,
      ),
      home: const _BootstrapScreen(),
    );
  }
}

/// Temporary shell for the pipeline milestone. The activation flow is the
/// first product screen and will replace this in the next implementation step.
class _BootstrapScreen extends StatelessWidget {
  const _BootstrapScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Text(
          'CoursePack',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
