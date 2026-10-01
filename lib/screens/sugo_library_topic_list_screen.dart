import 'package:flutter/material.dart';

import '../models/scheme_of_work.dart';
import '../models/sugo_library_note.dart';
import '../models/syllabus_models.dart';
import '../services/sugo_library_service.dart';
import '../services/template_repository.dart';
import 'sugo_library_notes_screen.dart';

/// "Sugo Library" Stage 4 continued + Stage 7 (owner request, 2026-09-29) —
/// one grade's topics, in the real order its own Scheme of Work already
/// teaches them (`allSchemeOfWorkEntries` — the exact same authoritative
/// ordering "Topics in the Scheme"/Syllabus Inspection use, never a raw
/// unordered syllabus dump), each tagged "Available Offline" or "Tap to
/// Download" against the shared manifest.
class SugoLibraryTopicListScreen extends StatefulWidget {
  const SugoLibraryTopicListScreen({super.key, required this.entry, this.repository, this.service});

  final TemplateManifestEntry entry;
  final TemplateRepository? repository;
  final SugoLibraryService? service;

  @override
  State<SugoLibraryTopicListScreen> createState() => _SugoLibraryTopicListScreenState();
}

class _SugoLibraryTopicListScreenState extends State<SugoLibraryTopicListScreen> {
  late final TemplateRepository _repository = widget.repository ?? TemplateRepository();
  late final SugoLibraryService _service = widget.service ?? SugoLibraryService();

  bool _loading = true;
  List<SchemeOfWorkEntry> _entries = const [];
  Map<String, String>? _manifest;
  final Map<String, bool> _downloadedById = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  SugoLibraryTopicId _idFor(SchemeOfWorkEntry entry) => SugoLibraryTopicId(
        curriculumCode: widget.entry.curriculumCode,
        subjectCode: widget.entry.subjectCode,
        gradeLevel: widget.entry.gradeLevel,
        topicName: entry.topic.name,
        subTopicName: entry.subTopic?.name,
      );

  Future<void> _bootstrap() async {
    final template = await _repository.loadSyllabus(
      curriculumCode: widget.entry.curriculumCode,
      subjectCode: widget.entry.subjectCode,
      gradeLevel: widget.entry.gradeLevel,
    );
    final entries = template == null ? const <SchemeOfWorkEntry>[] : allSchemeOfWorkEntries(template);
    final manifest = await _service.fetchManifest();

    final downloaded = <String, bool>{};
    for (final entry in entries) {
      final slug = _idFor(entry).slug;
      downloaded[slug] = await _service.isTopicDownloaded(slug, currentVersion: manifest?[slug]);
    }

    if (!mounted) return;
    setState(() {
      _entries = entries;
      _manifest = manifest;
      _downloadedById.addAll(downloaded);
      _loading = false;
    });
  }

  void _openNotes(SchemeOfWorkEntry entry) {
    final id = _idFor(entry);
    Navigator.of(context)
        .push(MaterialPageRoute(
          builder: (_) => SugoLibraryNotesScreen(
            topicId: id,
            manifestVersion: _manifest?[id.slug],
            service: _service,
          ),
        ))
        .then((_) {
      if (!mounted) return;
      // Refresh this tile's badge after returning — the notes screen may
      // have just downloaded it.
      _service.isTopicDownloaded(id.slug, currentVersion: _manifest?[id.slug]).then((downloaded) {
        if (mounted) setState(() => _downloadedById[id.slug] = downloaded);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.entry.subjectName} — ${widget.entry.gradeName}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No topics bundled yet.')))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    final id = _idFor(entry);
                    final isDownloaded = _downloadedById[id.slug] ?? false;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        title: Text(entry.title),
                        trailing: _OfflineBadge(available: isDownloaded),
                        onTap: () => _openNotes(entry),
                      ),
                    );
                  },
                ),
    );
  }
}

class _OfflineBadge extends StatelessWidget {
  const _OfflineBadge({required this.available});
  final bool available;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = available ? Colors.green.shade700 : colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: available ? Colors.green.shade50 : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 0.75),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(available ? Icons.offline_pin_outlined : Icons.download_outlined, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            available ? 'Available Offline' : 'Tap to Download',
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }
}
