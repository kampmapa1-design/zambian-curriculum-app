import 'package:flutter/material.dart';

import '../services/cdc_resources_service.dart';
import '../widgets/function_button.dart';
import 'cdc_resources_screen.dart';

/// Groups CDC Teaching Modules, CDC Syllabi, and ECZ Past Papers behind
/// one home-screen entry point (added 2026-09-02, replacing two separate
/// home-screen buttons — one of which had already internally combined
/// syllabi and past papers into sectioned lists). Each of the three is
/// its own real, separate function here — just reached one tap further
/// in, to keep the home screen itself less cluttered.
///
/// "New materials available" (2026-09-08, per explicit request): each
/// button's subtitle names how many resources of that kind are cataloged
/// but not yet seen (see CdcResourcesService.unseenCount) — a plain,
/// always-on-device count, not a push notification, since this app has
/// no notification infrastructure. The count clears once that specific
/// resource list is actually opened (see CdcResourcesScreen
/// ._markVisibleAsSeen).
class TeachingResourcesMenuScreen extends StatefulWidget {
  const TeachingResourcesMenuScreen({super.key, this.service});

  final CdcResourcesService? service;

  @override
  State<TeachingResourcesMenuScreen> createState() => _TeachingResourcesMenuScreenState();
}

class _TeachingResourcesMenuScreenState extends State<TeachingResourcesMenuScreen> {
  late final CdcResourcesService _service = widget.service ?? CdcResourcesService();
  int _pastPaperCount = 0;
  int _syllabusCount = 0;
  int _moduleCount = 0;

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    final pastPapers = await _service.unseenCount(resourceType: 'past_paper');
    final syllabi = await _service.unseenCount(resourceType: 'syllabus');
    final modules = await _service.unseenCount(resourceType: 'module');
    if (!mounted) return;
    setState(() {
      _pastPaperCount = pastPapers;
      _syllabusCount = syllabi;
      _moduleCount = modules;
    });
  }

  String _subtitle(String base, int newCount) => newCount == 0 ? base : '$base — $newCount new';

  /// Reloads the "new" counts once a resource screen is popped back to,
  /// so a badge just cleared by visiting that screen actually disappears
  /// here too rather than staying stale until the next full app launch.
  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    _loadCounts();
  }

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
            subtitle: _subtitle('Official past exam papers', _pastPaperCount),
            onTap: () => _open(const CdcResourcesScreen(resourceType: 'past_paper', title: 'ECZ Past Papers')),
          ),
          FunctionButton(
            icon: Icons.menu_book_outlined,
            label: 'CDC Syllabi',
            subtitle: _subtitle('Official syllabus documents', _syllabusCount),
            onTap: () => _open(const CdcResourcesScreen(resourceType: 'syllabus', title: 'CDC Syllabi')),
          ),
          FunctionButton(
            icon: Icons.collections_bookmark_outlined,
            label: 'CDC Teaching Modules',
            subtitle: _subtitle('Browse and download official Teaching Modules', _moduleCount),
            onTap: () => _open(const CdcResourcesScreen(resourceType: 'module', title: 'CDC Teaching Modules')),
          ),
        ],
      ),
    );
  }
}
