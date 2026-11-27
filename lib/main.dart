import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:coursepack/licence/device_code_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
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
      home: const DeviceCodeScreen(),
    );
  }
}
