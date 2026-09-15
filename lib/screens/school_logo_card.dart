import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/school_branding_service.dart';

/// Timetable Generation, Stage 12 — upload/remove the school's logo,
/// embedded as a header on every branded export (see
/// SchoolBrandingService). Shown at the top of Staff & Roles (reachable
/// from both mobile and web) since it's a whole-school setting, not a
/// timetable-specific one — a school sets its logo once, and every
/// export/pin/share downstream just picks it up automatically.
class SchoolLogoCard extends StatefulWidget {
  const SchoolLogoCard({required this.schoolId, required this.canManage, super.key});
  final String schoolId;
  final bool canManage;

  @override
  State<SchoolLogoCard> createState() => _SchoolLogoCardState();
}

class _SchoolLogoCardState extends State<SchoolLogoCard> {
  final _brandingService = SchoolBrandingService();
  bool _loading = true;
  bool _busy = false;
  Uint8List? _logoBytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await _brandingService.getLogoBytes(widget.schoolId);
    if (!mounted) return;
    setState(() {
      _logoBytes = bytes;
      _loading = false;
    });
  }

  Future<void> _upload() async {
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png']);
    if (result.isEmpty) return;
    final picked = result.first;
    final bytes = await picked.readAsBytes();
    final ext = (picked.extension ?? 'jpg').toLowerCase();
    final contentType = ext == 'png' ? 'image/png' : 'image/jpeg';
    setState(() => _busy = true);
    try {
      await _brandingService.uploadLogo(schoolId: widget.schoolId, bytes: bytes, contentType: contentType);
      if (!mounted) return;
      setState(() => _logoBytes = bytes);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Logo uploaded.')));
    } on SchoolBrandingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await _brandingService.removeLogo(widget.schoolId);
      if (!mounted) return;
      setState(() => _logoBytes = null);
    } on SchoolBrandingException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              height: 48,
              width: 48,
              decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(6)),
              child: _logoBytes != null
                  ? ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(_logoBytes!, fit: BoxFit.cover))
                  : const Icon(Icons.image_outlined, color: Colors.grey),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _logoBytes != null ? 'School logo — used on exported/shared/pinned timetables.' : 'No school logo set — exports still show the school name.',
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            if (widget.canManage) ...[
              if (_busy)
                const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
              else ...[
                TextButton(onPressed: _upload, child: Text(_logoBytes != null ? 'Replace' : 'Upload')),
                if (_logoBytes != null) TextButton(onPressed: _remove, child: const Text('Remove')),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
