import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/handwritten_list_document_service.dart';
import '../services/handwritten_list_transcription_service.dart';
import 'document_pages_capture_screen.dart';

/// "Capture Manual Scores" — for teachers who mark scripts entirely by
/// hand and keep a handwritten list rather than using this app's AI
/// grading pipeline. Deliberately simple and self-contained: no subject/
/// grade picker, no marking-scheme link, nothing else that could fail —
/// just capture → AI reads whatever pattern/table was on the page →
/// share as an actual editable Word document. Review and correction
/// happens in Word itself once shared, not inside this screen.
class CaptureManualScoresScreen extends StatefulWidget {
  const CaptureManualScoresScreen({super.key, this.transcriptionService, this.documentService});

  final HandwrittenListTranscriptionService? transcriptionService;
  final HandwrittenListDocumentService? documentService;

  @override
  State<CaptureManualScoresScreen> createState() => _CaptureManualScoresScreenState();
}

enum _Step { capturing, transcribing, done, error }

class _CaptureManualScoresScreenState extends State<CaptureManualScoresScreen> {
  late final HandwrittenListTranscriptionService _transcriptionService =
      widget.transcriptionService ?? HandwrittenListTranscriptionService();
  late final HandwrittenListDocumentService _documentService = widget.documentService ?? HandwrittenListDocumentService();

  _Step _step = _Step.capturing;
  String _statusText = '';
  String? _errorMessage;
  File? _generatedFile;
  String? _notes;
  int _rowCount = 0;
  List<File>? _capturedPages;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startCapture());
  }

  Future<void> _startCapture() async {
    final pages = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Capture Handwritten List',
          instructions: 'Photograph each page of the handwritten list — any pattern or table is fine, the app '
              'reproduces whatever is actually on the page.',
        ),
      ),
    );
    if (!mounted) return;
    if (pages == null || pages.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    _capturedPages = pages;
    await _transcribeAndBuild(pages);
  }

  Future<void> _transcribeAndBuild(List<File> pages) async {
    setState(() {
      _step = _Step.transcribing;
      _statusText = 'Starting…';
    });
    try {
      final table = await _transcriptionService.transcribe(
        pages,
        onProgress: (status) {
          if (mounted) setState(() => _statusText = status);
        },
      );
      if (!mounted) return;

      final arrangeAlphabetically = await _askArrangeAlphabetically();
      if (!mounted) return;
      final finalTable = arrangeAlphabetically ? table.sortedAlphabetically() : table;

      setState(() => _statusText = 'Building the Word document…');
      final file = await _documentService.generateDocx(finalTable, title: 'Captured List');
      if (!mounted) return;
      setState(() {
        _generatedFile = file;
        _notes = finalTable.notes;
        _rowCount = finalTable.rows.length;
        _step = _Step.done;
      });
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'Captured List'),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _step = _Step.error;
      });
    }
  }

  /// Matches the original spec's "Arrange list in alphabetical order?
  /// Yes/No" prompt — asked once transcription is done and the table's
  /// actual columns are known, so the sort can target whichever column
  /// genuinely looks like a name column.
  Future<bool> _askArrangeAlphabetically() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Arrange list in alphabetical order?'),
        content: const Text('The Word document can list rows alphabetically by name, or keep the order they were written in.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('No, keep original order')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Yes, arrange alphabetically')),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _retryTranscription() async {
    final pages = _capturedPages;
    if (pages == null) {
      setState(() {
        _step = _Step.capturing;
        _errorMessage = null;
      });
      await _startCapture();
      return;
    }
    setState(() => _errorMessage = null);
    await _transcribeAndBuild(pages);
  }

  Future<void> _shareAgain() async {
    final file = _generatedFile;
    if (file == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: 'Captured List'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Capture Manual Scores')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_step) {
            _Step.capturing => const CircularProgressIndicator(),
            _Step.transcribing => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_statusText.isEmpty ? 'Reading the list and building the Word document…' : _statusText),
                ],
              ),
            _Step.done => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 48, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('$_rowCount row(s) transcribed and shared as an editable Word document.', textAlign: TextAlign.center),
                  if (_notes case final n? when n.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.auto_awesome_outlined, size: 18),
                          const SizedBox(width: 8),
                          Expanded(child: Text(n, style: Theme.of(context).textTheme.bodySmall)),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _shareAgain,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share Again'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                ],
              ),
            _Step.error => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 12),
                  Text('Could not transcribe this list: $_errorMessage', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _retryTranscription,
                    child: const Text('Try Again'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _step = _Step.capturing;
                        _errorMessage = null;
                        _capturedPages = null;
                      });
                      _startCapture();
                    },
                    child: const Text('Re-capture Photos Instead'),
                  ),
                ],
              ),
          },
        ),
      ),
    );
  }
}
