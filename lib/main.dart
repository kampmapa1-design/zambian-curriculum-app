import 'package:flutter/material.dart';

import 'screens/subject_selector_screen.dart';

void main() {
  runApp(const CurriculumApp());
}

class CurriculumApp extends StatelessWidget {
  const CurriculumApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zambian Curriculum Companion',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const SubjectSelectorScreen(),
    );
  }
}
