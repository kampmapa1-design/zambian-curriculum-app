import 'dart:io';

import 'package:document_camera_frame/document_camera_frame.dart';
import 'package:flutter/material.dart';

/// A generic multi-page camera capture flow — the same auto-crop/deskew/
/// contrast-enhance pipeline BurstCaptureScreen uses for marking scripts,
/// but with no candidate-specific fields, for capturing any other
/// multi-page paper document (a question paper, an existing marking key,
/// a handwritten class list). Returns the captured page files in order,
/// or null if the teacher backs out before capturing anything.
class DocumentPagesCaptureScreen extends StatefulWidget {
  const DocumentPagesCaptureScreen({super.key, required this.title, this.instructions});

  final String title;
  final String? instructions;

  @override
  State<DocumentPagesCaptureScreen> createState() => _DocumentPagesCaptureScreenState();
}

class _DocumentPagesCaptureScreenState extends State<DocumentPagesCaptureScreen> {
  final List<File> _capturedPages = [];
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _captureNextPage());
  }

  Future<void> _captureNextPage() async {
    setState(() => _started = true);
    final result = await Navigator.of(context).push<DocumentCaptureData>(
      MaterialPageRoute(
        builder: (_) => DocumentCameraFrame(
          frameWidth: 320,
          frameHeight: 440,
          requireBothSides: false,
          enableAutoCapture: true,
          showCloseButton: true,
          imageQuality: 75,
          bottomHintText: 'Page ${_capturedPages.length + 1} — hold the document flat and steady',
          // No onDocumentSaved here — DocumentCameraFrame's own handleSave()
          // already pops itself with the result (per its own changelog: the
          // package "always pops itself with the result", onDocumentSaved is
          // only an optional side-channel notification, called BEFORE that
          // internal pop). Also popping here was a real double-pop bug: our
          // pop closed the camera route (correctly resolving this await),
          // then the plugin's own still-pending pop fired right after and
          // silently closed the NEXT route down — this screen itself — which
          // is why "Done" looked unresponsive and a second tap could reach a
          // stale/relaunched camera view. Just await the push's own result.
        ),
      ),
    );

    if (!mounted) return;
    if (result == null || !result.hasFrontSide || result.frontImagePath == null) {
      if (_capturedPages.isEmpty) Navigator.of(context).pop<List<File>?>(null);
      return;
    }
    setState(() => _capturedPages.add(File(result.frontImagePath!)));
  }

  void _removePage(int index) => setState(() => _capturedPages.removeAt(index));

  void _finish() => Navigator.of(context).pop<List<File>?>(_capturedPages);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: !_started
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (widget.instructions != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(widget.instructions!, style: const TextStyle(fontSize: 13)),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(child: Text('${_capturedPages.length} page(s) captured')),
                    ],
                  ),
                ),
                Expanded(
                  child: _capturedPages.isEmpty
                      ? const Center(child: Text('No pages captured yet.'))
                      : GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 0.75,
                          ),
                          itemCount: _capturedPages.length,
                          itemBuilder: (context, index) => Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(_capturedPages[index], fit: BoxFit.cover),
                              ),
                              Positioned(
                                top: 4,
                                left: 4,
                                child: CircleAvatar(
                                  radius: 12,
                                  backgroundColor: Colors.black54,
                                  child: Text('${index + 1}', style: const TextStyle(fontSize: 12, color: Colors.white)),
                                ),
                              ),
                              Positioned(
                                top: 0,
                                right: 0,
                                child: IconButton(
                                  icon: const Icon(Icons.close, color: Colors.white, shadows: [Shadow(blurRadius: 4)]),
                                  onPressed: () => _removePage(index),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _captureNextPage,
                            icon: const Icon(Icons.add_a_photo_outlined),
                            label: const Text('Capture Next Page'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _capturedPages.isEmpty ? null : _finish,
                            icon: const Icon(Icons.check),
                            label: const Text('Done'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
