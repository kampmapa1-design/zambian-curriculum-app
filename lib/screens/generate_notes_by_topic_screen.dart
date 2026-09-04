import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/free_topic_notes_service.dart';
import '../services/pptx_document_service.dart';
import '../services/teaching_notes_document_service.dart';
import '../utils/text_utils.dart';

/// "Generate Notes & Slides by Topic" (2026-09-04, per explicit request) —
/// sits alongside Search and Browse on the Teaching Notes entry point, but
/// takes a topic typed directly rather than one picked from the bundled
/// syllabus. Three fixed output shapes: Paragraphs (flowing prose, up to
/// 700 words), Bulletins (bullet points, up to ~6 printed pages), Slides
/// (exactly 6 slides, 4-5 points each). Deliberately not labeled as
/// AI-powered anywhere in this screen's own text, per explicit request —
/// see FreeTopicNotesService's own doc comment for what actually powers it.
class GenerateNotesByTopicScreen extends StatefulWidget {
  const GenerateNotesByTopicScreen({super.key, this.notesService, this.documentService, this.pptxService});

  final FreeTopicNotesService? notesService;
  final TeachingNotesDocumentService? documentService;
  final PptxDocumentService? pptxService;

  @override
  State<GenerateNotesByTopicScreen> createState() => _GenerateNotesByTopicScreenState();
}

class _GenerateNotesByTopicScreenState extends State<GenerateNotesByTopicScreen> {
  late final FreeTopicNotesService _notesService = widget.notesService ?? FreeTopicNotesService();
  late final TeachingNotesDocumentService _documentService = widget.documentService ?? TeachingNotesDocumentService();
  late final PptxDocumentService _pptxService = widget.pptxService ?? PptxDocumentService();

  final _topicController = TextEditingController();
  FreeTopicFormat? _generating;

  @override
  void dispose() {
    _topicController.dispose();
    super.dispose();
  }

  Future<void> _generate(FreeTopicFormat format) async {
    final topic = _topicController.text.trim();
    if (topic.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Type a topic first.')),
      );
      return;
    }

    setState(() => _generating = format);
    try {
      final result = await _notesService.generate(topic: topic, format: format);
      if (!mounted) return;

      if (format == FreeTopicFormat.slides) {
        final outline = result.outline;
        if (outline == null) throw StateError('No slides returned.');
        final file = await _pptxService.generate(outline);
        if (!mounted) return;
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: outline.deckTitle));
        return;
      }

      final cleaned = stripMarkdownArtifacts(result.text ?? '');
      final text = format == FreeTopicFormat.paragraph
          ? capWords(cleaned, 700, trailingNote: '(Trimmed to stay within the 700-word limit.)')
          : cleaned;
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => _NotesPreviewScreen(topic: topic, notes: text, documentService: _documentService)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not generate: $error')));
    } finally {
      if (mounted) setState(() => _generating = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _generating != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Generate Notes & Slides by Topic')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Type any topic, then pick how you\'d like it summarized.'),
          const SizedBox(height: 12),
          TextField(
            controller: _topicController,
            decoration: const InputDecoration(
              labelText: 'Topic',
              hintText: 'e.g. "The Water Cycle", "Causes of the First World War"',
              border: OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.sentences,
            enabled: !busy,
          ),
          const SizedBox(height: 20),
          _formatTile(
            format: FreeTopicFormat.bulletin,
            icon: Icons.format_list_bulleted,
            title: 'Bulletin',
            subtitle: 'Bullet points in a Word document — up to 6 pages, less if the topic wraps up sooner.',
          ),
          const SizedBox(height: 8),
          _formatTile(
            format: FreeTopicFormat.slides,
            icon: Icons.slideshow_outlined,
            title: 'Slides',
            subtitle: '6 PowerPoint slides, 4-5 points each — shared as soon as they\'re ready.',
          ),
          const SizedBox(height: 8),
          _formatTile(
            format: FreeTopicFormat.paragraph,
            icon: Icons.article_outlined,
            title: 'Paragraphs',
            subtitle: 'Flowing prose, up to 700 words.',
          ),
        ],
      ),
    );
  }

  Widget _formatTile({
    required FreeTopicFormat format,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final busy = _generating == format;
    final disabled = _generating != null && _generating != format;
    return Card(
      child: ListTile(
        leading: busy
            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
            : CircleAvatar(child: Icon(icon)),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        enabled: !disabled,
        onTap: disabled || busy ? null : () => _generate(format),
      ),
    );
  }
}

class _NotesPreviewScreen extends StatefulWidget {
  const _NotesPreviewScreen({required this.topic, required this.notes, required this.documentService});

  final String topic;
  final String notes;
  final TeachingNotesDocumentService documentService;

  @override
  State<_NotesPreviewScreen> createState() => _NotesPreviewScreenState();
}

class _NotesPreviewScreenState extends State<_NotesPreviewScreen> {
  bool _sharing = false;

  Future<void> _share({required bool asDocx}) async {
    setState(() => _sharing = true);
    try {
      final file = asDocx
          ? await widget.documentService.generateDocx(title: widget.topic, notes: widget.notes)
          : await widget.documentService.generatePdf(title: widget.topic, notes: widget.notes);
      if (!mounted) return;
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: widget.topic));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create the file: $error')));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.topic)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText(widget.notes),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _sharing ? null : () => _share(asDocx: true),
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Share as Word'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _sharing ? null : () => _share(asDocx: false),
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Share as PDF'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
