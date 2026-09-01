import 'package:flutter/material.dart';

import '../widgets/function_button.dart';
import 'cdc_resources_screen.dart';

/// Groups CDC Teaching Modules, CDC Syllabi, and ECZ Past Papers behind
/// one home-screen entry point (added 2026-09-02, replacing two separate
/// home-screen buttons — one of which had already internally combined
/// syllabi and past papers into sectioned lists). Each of the three is
/// its own real, separate function here — just reached one tap further
/// in, to keep the home screen itself less cluttered.
class TeachingResourcesMenuScreen extends StatelessWidget {
  const TeachingResourcesMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Teaching Modules, Syllabi & Past Papers')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FunctionButton(
            icon: Icons.description_outlined,
            label: 'ECZ Past Papers',
            subtitle: 'Official past exam papers',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CdcResourcesScreen(resourceType: 'past_paper', title: 'ECZ Past Papers'),
              ),
            ),
          ),
          FunctionButton(
            icon: Icons.menu_book_outlined,
            label: 'CDC Syllabi',
            subtitle: 'Official syllabus documents',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CdcResourcesScreen(resourceType: 'syllabus', title: 'CDC Syllabi'),
              ),
            ),
          ),
          FunctionButton(
            icon: Icons.collections_bookmark_outlined,
            label: 'CDC Teaching Modules',
            subtitle: 'Browse and download official Teaching Modules',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CdcResourcesScreen(resourceType: 'module', title: 'CDC Teaching Modules'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
