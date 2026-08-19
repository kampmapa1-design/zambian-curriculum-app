import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/cdc_resource.dart';
import '../services/cdc_resources_service.dart';

/// Lists CDC Digital Library resources (Teaching Modules, syllabi, etc.) for
/// on-demand download. The catalog itself is fetched at most weekly and
/// cached locally so it's browsable offline; downloading an actual file
/// still needs a connection — see [CdcResourcesService].
class CdcResourcesScreen extends StatefulWidget {
  const CdcResourcesScreen({super.key, this.service});

  final CdcResourcesService? service;

  @override
  State<CdcResourcesScreen> createState() => _CdcResourcesScreenState();
}

class _CdcResourcesScreenState extends State<CdcResourcesScreen> {
  late final CdcResourcesService _service = widget.service ?? CdcResourcesService();

  bool _loading = true;
  bool _refreshing = false;
  bool _online = true;
  String? _error;
  CdcCatalog _catalog = CdcCatalog.empty();
  DateTime? _lastCheckedAt;
  final Set<String> _downloadingUrls = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final cached = await _service.loadCached();
    final lastChecked = await _service.lastCheckedAt;
    final online = await _service.isOnline;
    if (!mounted) return;
    setState(() {
      _catalog = cached;
      _lastCheckedAt = lastChecked;
      _online = online;
      _loading = false;
    });
    // Opportunistic — only actually calls the function if online and due.
    unawaited(_refresh(force: false));
  }

  Future<void> _refresh({required bool force}) async {
    setState(() => _refreshing = true);
    try {
      final updated = await _service.refreshIfDue(force: force);
      final lastChecked = await _service.lastCheckedAt;
      final online = await _service.isOnline;
      if (!mounted) return;
      setState(() {
        if (updated != null) _catalog = updated;
        _lastCheckedAt = lastChecked;
        _online = online;
        _error = null;
      });
    } on CdcResourcesUnavailable catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _downloadAndShare(CdcResource resource) async {
    setState(() => _downloadingUrls.add(resource.url));
    try {
      final file = await _service.downloadResource(resource);
      if (!mounted) return;
      await Share.shareXFiles([XFile(file.path)], subject: resource.title);
    } on CdcResourcesUnavailable catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $error')));
    } finally {
      if (mounted) setState(() => _downloadingUrls.remove(resource.url));
    }
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CDC Resources'),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
            tooltip: 'Check for updates',
            onPressed: _refreshing ? null : () => _refresh(force: true),
          ),
        ],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () => _refresh(force: true),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _lastCheckedAt == null
                        ? 'Catalog never checked yet'
                        : 'Last checked ${_relativeTime(_lastCheckedAt!)}',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  if (!_online) ...[
                    const SizedBox(height: 4),
                    Text(
                      "You're offline — showing the last cached list. Downloads and catalog "
                      'checks need a connection.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 4),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_catalog.resources.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('No resources catalogued yet. Pull down or tap refresh while online to check.'),
              ),
            )
          else
            for (final resource in _catalog.resources) _buildResourceTile(resource),
        ],
      ),
    );
  }

  Widget _buildResourceTile(CdcResource resource) {
    final downloading = _downloadingUrls.contains(resource.url);
    final subtitleParts = [
      if (resource.subjectName != null) resource.subjectName!,
      if (resource.level != null) resource.level!,
      if (resource.term != null) resource.term!,
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(resource.title),
        subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
        trailing: downloading
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(
                icon: const Icon(Icons.download_outlined),
                tooltip: 'Download and share',
                onPressed: () => _downloadAndShare(resource),
              ),
      ),
    );
  }
}
