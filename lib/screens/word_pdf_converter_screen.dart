import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf_manipulator/io.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';
import 'package:share_plus/share_plus.dart';

import '../services/entitlement_service.dart';

/// Admin Tools — Word↔PDF Converter (Stage 2/3). Converts a picked .docx
/// file to PDF entirely on-device via `pdf_manipulator` (a local Rust
/// engine, no network call — this is direct document rendering, not an AI
/// feature, so it never touches the Gemini backend or its cost). Free tier
/// is capped at 10 pages; anything longer needs a subscription or one
/// watched rewarded ad (see EntitlementService/RewardedAdService) —
/// checked *after* conversion, since a .docx's real page count isn't
/// knowable until it's actually paginated.
class WordPdfConverterScreen extends StatefulWidget {
  const WordPdfConverterScreen({super.key});

  static const kFreePageLimit = 10;

  @override
  State<WordPdfConverterScreen> createState() => _WordPdfConverterScreenState();
}

enum _Stage { idle, converting, readyOverLimit, watchingAd, readyToSave, error }

class _WordPdfConverterScreenState extends State<WordPdfConverterScreen> {
  final _pdf = Pdf();

  _Stage _stage = _Stage.idle;
  String? _pickedFileName;
  File? _convertedFile;
  int? _pageCount;
  String? _errorMessage;

  @override
  void dispose() {
    _pdf.dispose();
    super.dispose();
  }

  Future<void> _pickAndConvert() async {
    setState(() {
      _stage = _Stage.idle;
      _errorMessage = null;
    });
    final results = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['docx']);
    if (results.isEmpty || !mounted) return;
    final picked = results.single;

    setState(() {
      _stage = _Stage.converting;
      _pickedFileName = picked.name;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final baseName = p.basenameWithoutExtension(picked.name);
      final outputFile = File(p.join(tempDir.path, '${baseName}_${DateTime.now().millisecondsSinceEpoch}.pdf'));

      final sourceBytes = await picked.readAsBytes();
      final tempInputFile = File(p.join(tempDir.path, picked.name));
      await tempInputFile.writeAsBytes(sourceBytes);

      final sink = await FileSink.create(outputFile);
      try {
        await _pdf.convertToPdf(FileSource(tempInputFile), sink, format: PdfDocumentFormat.docx);
      } finally {
        await sink.close();
      }
      await tempInputFile.delete();

      final doc = await _pdf.open(FileSource(outputFile));
      final pageCount = doc.pageCount;
      await doc.dispose();

      if (!mounted) return;

      final withinFreeLimit = pageCount <= WordPdfConverterScreen.kFreePageLimit;
      final entitled = EntitlementService.instance.hasLocalEntitlement;
      setState(() {
        _convertedFile = outputFile;
        _pageCount = pageCount;
        _stage = (withinFreeLimit || entitled) ? _Stage.readyToSave : _Stage.readyOverLimit;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.error;
        _errorMessage = 'Could not convert this document: $error';
      });
    }
  }

  Future<void> _watchAdToUnlock() async {
    setState(() => _stage = _Stage.watchingAd);
    try {
      final watched = await EntitlementService.instance.watchRewardedAd();
      if (!mounted) return;
      setState(() => _stage = watched ? _Stage.readyToSave : _Stage.readyOverLimit);
      if (!watched && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("The ad wasn't watched to completion, so this stays locked.")),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _stage = _Stage.readyOverLimit);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not show an ad right now: $error')),
      );
    }
  }

  Future<void> _shareResult() async {
    final file = _convertedFile;
    if (file == null) return;
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: _pickedFileName));
  }

  void _reset() {
    setState(() {
      _stage = _Stage.idle;
      _pickedFileName = null;
      _convertedFile = null;
      _pageCount = null;
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Word ↔ PDF Converter')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_stage) {
      case _Stage.idle:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf_outlined, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Convert a Word document (.docx) to PDF — entirely on-device, no internet needed.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Free: up to ${WordPdfConverterScreen.kFreePageLimit} pages per document.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _pickAndConvert,
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Choose a .docx file'),
            ),
          ],
        );
      case _Stage.converting:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Converting "${_pickedFileName ?? ''}"…'),
          ],
        );
      case _Stage.readyOverLimit:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 56),
            const SizedBox(height: 16),
            Text(
              '"${_pickedFileName ?? ''}" converted to $_pageCount pages — over the free '
              '${WordPdfConverterScreen.kFreePageLimit}-page limit.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text(
              'Smart Teacher runs on ads and subscriptions to stay free/affordable — please watch this '
              'short video to unlock your conversion.',
              textAlign: TextAlign.center,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _watchAdToUnlock,
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Watch ad to unlock'),
            ),
            TextButton(onPressed: _reset, child: const Text('Choose a different file')),
          ],
        );
      case _Stage.watchingAd:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Loading your ad…'),
          ],
        );
      case _Stage.readyToSave:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 56),
            const SizedBox(height: 16),
            Text(
              '"${_pickedFileName ?? ''}" converted ($_pageCount page${_pageCount == 1 ? '' : 's'}).',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _shareResult,
              icon: const Icon(Icons.share_outlined),
              label: const Text('Share / Save PDF'),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _reset, child: const Text('Convert another file')),
          ],
        );
      case _Stage.error:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56),
            const SizedBox(height: 16),
            Text(_errorMessage ?? 'Something went wrong.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(onPressed: _reset, child: const Text('Try again')),
          ],
        );
    }
  }
}
