import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import '../models/cdc_resource.dart';
import '../services/cdc_resources_service.dart';
import '../services/device_downloads_service.dart';
import '../services/subject_content_repository.dart';

enum _DownloadDestination { database, device }

/// One grouped section of the resource list — all resources of
/// [resourceType] ('module', 'syllabus', or 'past_paper'), under [heading]
/// (omit for the first/default section so it isn't redundantly labeled).
class CdcResourceSection {
  final String resourceType;
  final String? heading;

  const CdcResourceSection({required this.resourceType, this.heading});
}

/// Lists CDC Digital Library resources (Teaching Modules, syllabi, ECZ past
/// papers, etc.) for on-demand download. The catalog itself is fetched at
/// most weekly and cached locally so it's browsable offline; downloading an
/// actual file still needs a connection — see [CdcResourcesService].
class CdcResourcesScreen extends StatefulWidget {
  const CdcResourcesScreen({
    super.key,
    this.service,
    this.resourceType,
    this.sections,
    this.title = 'CDC Resources',
  });

  final CdcResourcesService? service;

  /// 'module', 'syllabus', or 'past_paper' to show only that kind (see
  /// [CdcResource.resourceType]), or null to show everything. Ignored when
  /// [sections] is given.
  final String? resourceType;

  /// Show resources grouped into labeled sections (e.g. syllabi first, then
  /// an "ECZ Past Papers" sub-heading) instead of one flat list. Takes
  /// precedence over [resourceType] when both are given.
  final List<CdcResourceSection>? sections;
  final String title;

  @override
  State<CdcResourcesScreen> createState() => _CdcResourcesScreenState();
}

class _CdcResourcesScreenState extends State<CdcResourcesScreen> {
  late final CdcResourcesService _service = widget.service ?? CdcResourcesService();
  final SubjectContentRepository _subjectContentRepository = SubjectContentRepository();
  final DeviceDownloadsService _deviceDownloadsService = DeviceDownloadsService();

  static const _autoDownloadPromptKey = 'subject_content_last_autoprompt_at';
  static const _autoDownloadInterval = Duration(days: 7);

  bool _loading = true;
  bool _refreshing = false;
  bool _online = true;
  String? _error;
  CdcCatalog _catalog = CdcCatalog.empty();
  DateTime? _lastCheckedAt;
  final Set<String> _downloadingUrls = {};
  bool _bulkDownloading = false;

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
    // Chained (not parallel) so the auto-download prompt sees a
    // just-refreshed catalog rather than possibly-stale cached data.
    unawaited(_refresh(force: false).then((_) => _maybePromptAutoDownload()));
  }

  /// Once a week (per device, only from the "CDC Teaching Modules" screen),
  /// checks whether any Teaching Modules in the catalog aren't yet in the
  /// on-device Subject Content Database and — if so — asks before bulk
  /// downloading them. Never downloads silently: this can mean a genuinely
  /// large amount of data and device storage, so it always asks first, same
  /// as any other file download in this app.
  Future<void> _maybePromptAutoDownload() async {
    if (widget.resourceType != 'module' || !mounted) return;
    if (!await _service.isOnline) return;

    final prefs = await SharedPreferences.getInstance();
    final lastRaw = prefs.getString(_autoDownloadPromptKey);
    final last = lastRaw == null ? null : DateTime.tryParse(lastRaw);
    if (last != null && DateTime.now().difference(last) < _autoDownloadInterval) return;
    await prefs.setString(_autoDownloadPromptKey, DateTime.now().toIso8601String());

    final stored = await _subjectContentRepository.loadCatalog();
    final storedUrls = stored.items.map((i) => i.sourceUrl).toSet();
    final missing = _catalog.resources.where((r) => r.resourceType == 'module' && !storedUrls.contains(r.url)).toList();
    if (missing.isEmpty || !mounted) return;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New Teaching Modules available'),
        content: Text(
          '${missing.length} Teaching Module${missing.length == 1 ? '' : 's'} '
          "${missing.length == 1 ? "isn't" : "aren't"} in your on-device Subject Content Database yet. "
          'Download ${missing.length == 1 ? 'it' : 'them all'} now for offline lesson and notes '
          'preparation? This uses your data connection and device storage.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Download')),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    await _bulkDownloadToDatabase(missing);
  }

  Future<void> _bulkDownloadToDatabase(List<CdcResource> resources) async {
    setState(() => _bulkDownloading = true);
    var done = 0;
    for (final resource in resources) {
      try {
        final file = await _service.downloadResource(resource);
        final bytes = await file.readAsBytes();
        await _subjectContentRepository.store(
          title: resource.title,
          subjectName: resource.subjectName ?? 'Unspecified',
          resourceType: resource.resourceType,
          sourceUrl: resource.url,
          bytes: bytes,
        );
        done++;
      } catch (_) {
        // Skip failures (offline mid-batch, a bad link, etc.) — keep going
        // with the rest rather than aborting the whole batch.
      }
    }
    if (!mounted) return;
    setState(() => _bulkDownloading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved $done of ${resources.length} Teaching Module(s) to your Subject Content Database.'),
      ),
    );
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

  Future<_DownloadDestination?> _askDownloadDestination(CdcResource resource) {
    return showDialog<_DownloadDestination>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Save "${resource.title}"'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_DownloadDestination.database),
            child: const ListTile(
              leading: Icon(Icons.storage_outlined),
              title: Text('Subject Content Database'),
              subtitle: Text('Kept on-device, reused for lesson plans and teaching notes'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(_DownloadDestination.device),
            child: const ListTile(
              leading: Icon(Icons.download_outlined),
              title: Text('Save to device'),
              subtitle: Text('Goes to your Downloads folder — open it anytime from Files'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndShare(CdcResource resource) async {
    final destination = await _askDownloadDestination(resource);
    if (destination == null || !mounted) return;

    setState(() => _downloadingUrls.add(resource.url));
    try {
      final file = await _service.downloadResource(resource);
      if (!mounted) return;
      if (destination == _DownloadDestination.database) {
        final bytes = await file.readAsBytes();
        await _subjectContentRepository.store(
          title: resource.title,
          subjectName: resource.subjectName ?? 'Unspecified',
          resourceType: resource.resourceType,
          sourceUrl: resource.url,
          bytes: bytes,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to your Subject Content Database.')),
        );
      } else {
        final fileName = file.uri.pathSegments.last;
        try {
          await _deviceDownloadsService.saveToDownloads(file: file, fileName: fileName);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Saved to your device — check your Downloads folder.')),
          );
        } on DeviceDownloadsUnsupported {
          // Older Android (pre-10) or a non-Android platform — no direct
          // Downloads-folder API available there, so fall back to the
          // share sheet, same as this always worked before.
          if (!mounted) return;
          await SharePlus.instance.share(ShareParams(files: [XFile(file.path)], subject: resource.title));
        }
      }
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

  List<CdcResource> get _visibleResources => widget.resourceType == null
      ? _catalog.resources
      : _catalog.resources.where((r) => r.resourceType == widget.resourceType).toList();

  List<CdcResource> _resourcesFor(String resourceType) =>
      _catalog.resources.where((r) => r.resourceType == resourceType).toList();

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
        title: Text(widget.title),
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
          if (_bulkDownloading) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
            const SizedBox(height: 4),
            const Text('Downloading Teaching Modules to your Subject Content Database…'),
          ],
          const SizedBox(height: 12),
          if (widget.sections != null)
            ..._buildSections(widget.sections!)
          else if (_visibleResources.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                child: Text('No resources catalogued yet. Pull down or tap refresh while online to check.'),
              ),
            )
          else
            for (final resource in _visibleResources) _buildResourceTile(resource),
        ],
      ),
    );
  }

  List<Widget> _buildSections(List<CdcResourceSection> sections) {
    final anyResources = sections.any((s) => _resourcesFor(s.resourceType).isNotEmpty);
    if (!anyResources) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(
            child: Text('No resources catalogued yet. Pull down or tap refresh while online to check.'),
          ),
        ),
      ];
    }
    final widgets = <Widget>[];
    for (final section in sections) {
      final resources = _resourcesFor(section.resourceType);
      if (resources.isEmpty) continue;
      if (section.heading != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
          child: Text(section.heading!, style: Theme.of(context).textTheme.titleMedium),
        ));
      }
      widgets.addAll([for (final resource in resources) _buildResourceTile(resource)]);
    }
    return widgets;
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
