import 'package:flutter/material.dart';

import '../models/syllabus_models.dart';
import '../services/template_repository.dart';
import 'sugo_library_topic_list_screen.dart';

/// "Sugo Library" Stage 3-4 (owner request, 2026-09-29) — a curriculum
/// toggle shown before anything else loads, then a Subject → Grade
/// drill-down for the selected curriculum. Entirely on-device/offline (the
/// same bundled manifest every other syllabus picker in this app already
/// reads) — no network needed to browse WHICH topics exist; only opening a
/// specific topic's notes (see SugoLibraryTopicListScreen/NotesScreen)
/// touches Firestore.
class SugoLibraryScreen extends StatefulWidget {
  const SugoLibraryScreen({super.key, this.repository});

  final TemplateRepository? repository;

  @override
  State<SugoLibraryScreen> createState() => _SugoLibraryScreenState();
}

enum _Curriculum { obc, cbc }

class _SugoLibraryScreenState extends State<SugoLibraryScreen> {
  late final TemplateRepository _repository = widget.repository ?? TemplateRepository();

  bool _loading = true;
  List<TemplateManifestEntry> _manifest = const [];
  _Curriculum _selected = _Curriculum.obc;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _repository.ensureAllSeeded();
    final manifest = await _repository.loadManifest();
    if (!mounted) return;
    setState(() {
      _manifest = manifest;
      _loading = false;
    });
  }

  // Same "CBC vs everything else" split SubjectGradeTopicPickerScreen
  // already uses on the teacher side (assets/syllabi's own curriculum
  // codes are OBC_2013 / CBC_2023 today, but this stays correct for any
  // future non-CBC curriculum too).
  List<TemplateManifestEntry> get _entriesForSelected => _manifest
      .where((e) => (e.curriculumCode.toUpperCase().contains('CBC')) == (_selected == _Curriculum.cbc))
      .toList();

  Map<String, List<TemplateManifestEntry>> get _bySubject {
    final grouped = <String, List<TemplateManifestEntry>>{};
    for (final entry in _entriesForSelected) {
      grouped.putIfAbsent(entry.subjectName, () => []).add(entry);
    }
    for (final grades in grouped.values) {
      grades.sort((a, b) => a.gradeLevel.compareTo(b.gradeLevel));
    }
    return grouped;
  }

  void _openGrade(TemplateManifestEntry entry) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SugoLibraryTopicListScreen(entry: entry, repository: _repository),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bySubject = _bySubject;
    final subjectNames = bySubject.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Sugo Library')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SegmentedButton<_Curriculum>(
                    segments: const [
                      ButtonSegment(value: _Curriculum.obc, label: Text('OBC')),
                      ButtonSegment(value: _Curriculum.cbc, label: Text('CBC')),
                    ],
                    selected: {_selected},
                    onSelectionChanged: (s) => setState(() => _selected = s.first),
                  ),
                ),
                Expanded(
                  child: subjectNames.isEmpty
                      ? const Center(child: Text('No subjects bundled yet for this curriculum.'))
                      : ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          children: [
                            for (final subjectName in subjectNames)
                              Card(
                                margin: const EdgeInsets.only(bottom: 6),
                                child: Theme(
                                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                                  child: ExpansionTile(
                                    title: Text(subjectName),
                                    children: [
                                      for (final entry in bySubject[subjectName]!)
                                        ListTile(
                                          title: Text(entry.gradeName),
                                          trailing: const Icon(Icons.chevron_right_outlined),
                                          onTap: () => _openGrade(entry),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}
