import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../services/handwriting_document_service.dart';
import '../services/handwriting_document_transcription_service.dart';
import 'document_pages_capture_screen.dart';

enum _InputSource { device, camera }

enum _Step { choosingSource, capturing, transcribing, done, error }

/// "Handwriting to Word Document Conversion" — a top-level home-screen
/// function, separate from AI-Assisted Marking. Photographs (or already-
/// saved photos of) any handwritten page(s) — notes, a letter, anything —
/// and uses AI to reconstruct the full content as a real, structured,
/// editable Word document (headings/paragraphs/lists preserved, not just
/// a flat text dump). Ends with a genuine choice: save the file to the
/// device, or share it — both real actions, not placeholders.
class HandwritingToWordScreen extends StatefulWidget {
  const HandwritingToWordScreen({super.key, this.transcriptionService, this.documentService});

  final HandwritingDocumentTranscriptionService? transcriptionService;
  final HandwritingDocumentService? documentService;

  @override
  State<HandwritingToWordScreen> createState() => _HandwritingToWordScreenState();
}

class _HandwritingToWordScreenState extends State<HandwritingToWordScreen> {
  late final HandwritingDocumentTranscriptionService _transcriptionService =
      widget.transcriptionService ?? HandwritingDocumentTranscriptionService();
  late final HandwritingDocumentService _documentService = widget.documentService ?? HandwritingDocumentService();

  _Step _step = _Step.choosingSource;
  String _statusText = '';
  String? _errorMessage;
  File? _generatedFile;
  String? _documentTitle;
  String? _notes;
  int _blockCount = 0;
  List<File>? _capturedPages;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _chooseSource());
  }

  Future<void> _chooseSource() async {
    final source = await showDialog<_InputSource>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Add a handwritten document'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_InputSource.device),
            child: const Row(
              children: [
                Icon(Icons.photo_library_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Upload from device')),
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_InputSource.camera),
            child: const Row(
              children: [
                Icon(Icons.camera_alt_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Upload from camera')),
              ],
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (source == null) {
      Navigator.of(context).pop();
      return;
    }

    if (source == _InputSource.device) {
      await _pickFromDevice();
    } else {
      await _captureFromCamera();
    }
  }

  Future<void> _pickFromDevice() async {
    final results = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png']);
    if (!mounted) return;
    if (results.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    final files = [for (final f in results) if (f.path != null) File(f.path!)];
    if (files.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    _capturedPages = files;
    await _transcribeAndBuild(files);
  }

  Future<void> _captureFromCamera() async {
    setState(() => _step = _Step.capturing);
    final pages = await Navigator.of(context).push<List<File>>(
      MaterialPageRoute(
        builder: (_) => const DocumentPagesCaptureScreen(
          title: 'Capture Handwritten Document',
          instructions: 'Photograph each page — the app reconstructs everything genuinely written on the page(s), '
              'not just a table or list.',
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
      final document = await _transcriptionService.transcribe(
        pages,
        onProgress: (status) {
          if (mounted) setState(() => _statusText = status);
        },
      );
      if (!mounted) return;

      setState(() => _statusText = 'Building the Word document…');
      final file = await _documentService.generateDocx(document);
      if (!mounted) return;
      setState(() {
        _generatedFile = file;
        _documentTitle = document.title;
        _notes = document.notes;
        _blockCount = document.blocks.length;
        _step = _Step.done;
      });

      await _askSaveOrShare();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
        _step = _Step.error;
      });
    }
  }

  Future<void> _retryTranscription() async {
    final pages = _capturedPages;
    if (pages == null) {
      setState(() {
        _step = _Step.choosingSource;
        _errorMessage = null;
      });
      await _chooseSource();
      return;
    }
    setState(() => _errorMessage = null);
    await _transcribeAndBuild(pages);
  }

  /// The real "Save To Device" / "Share The File" choice — both genuinely
  /// wired up, not placeholders. Shown automatically once conversion
  /// finishes, and re-offered via the on-screen buttons afterwards.
  Future<void> _askSaveOrShare() async {
    final choice = await showDialog<_SaveChoice>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Document ready'),
        content: const Text('What would you like to do with the converted Word document?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(_SaveChoice.share), child: const Text('Share the File')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(_SaveChoice.save), child: const Text('Save to Device')),
        ],
      ),
    );
    if (choice == _SaveChoice.save) {
      await _saveToDevice();
    } else if (choice == _SaveChoice.share) {
      await _shareFile();
    }
  }

  Future<void> _saveToDevice() async {
    final file = _generatedFile;
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      final name = p.basenameWithoutExtension(file.path);
      await FileSaver.instance.saveFile(
        name: name,
        bytes: bytes,
        fileExtension: 'docx',
        mimeType: MimeType.microsoftWord,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved to your device.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save the file: $error')),
      );
    }
  }

  Future<void> _shareFile() async {
    final file = _generatedFile;
    if (file == null) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: _documentTitle ?? 'Converted Document'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Handwriting to Word Document Conversion')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: switch (_step) {
            _Step.choosingSource || _Step.capturing => const CircularProgressIndicator(),
            _Step.transcribing => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(_statusText.isEmpty ? 'Converting your document…' : _statusText),
                ],
              ),
            _Step.done => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle_outline, size: 48, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  Text(
                    '"${_documentTitle ?? 'Document'}" converted — $_blockCount section(s) reconstructed as an editable Word document.',
                    textAlign: TextAlign.center,
                  ),
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
                    onPressed: _saveToDevice,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Save to Device'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _shareFile,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Share the File'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
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
                  Text('Could not convert this document: $_errorMessage', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: _retryTranscription, child: const Text('Try Again')),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _step = _Step.choosingSource;
                        _errorMessage = null;
                        _capturedPages = null;
                      });
                      _chooseSource();
                    },
                    child: const Text('Start Over'),
                  ),
                ],
              ),
          },
        ),
      ),
    );
  }
}

enum _SaveChoice { save, share }
