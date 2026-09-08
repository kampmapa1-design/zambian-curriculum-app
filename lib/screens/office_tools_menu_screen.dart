import 'package:flutter/material.dart';

import '../widgets/function_button.dart';
import 'minutes_maker_screen.dart';
import 'word_pdf_converter_screen.dart';

/// Groups Minutes Maker and Word ↔ PDF Converter behind one home-screen
/// entry point (2026-09-08, per explicit request) — same "combine related
/// utilities one level down, home screen stays uncluttered" pattern
/// already used by [TeachingResourcesMenuScreen]/[AssignmentsTestsMenuScreen].
/// Each keeps its exact prior function, completely separate from the
/// other — only where they're reached from changed.
class OfficeToolsMenuScreen extends StatelessWidget {
  const OfficeToolsMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Minutes Maker & Word ↔ PDF Converter')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FunctionButton(
            icon: Icons.groups_outlined,
            label: 'Minutes Maker',
            subtitle: 'Photograph handwritten meeting notes, get back formatted minutes',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MinutesMakerScreen()),
            ),
          ),
          FunctionButton(
            icon: Icons.picture_as_pdf_outlined,
            label: 'Word ↔ PDF Converter',
            subtitle: 'Convert a .docx file to PDF, entirely on-device',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WordPdfConverterScreen()),
            ),
          ),
        ],
      ),
    );
  }
}
