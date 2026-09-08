import 'package:flutter/material.dart';

import '../screens/teaching_resources_menu_screen.dart';
import '../services/cdc_resources_service.dart';

/// "New materials available" (2026-09-08, per explicit request): a
/// home-screen banner that surfaces whenever the CDC Digital Library
/// catalog (Teaching Modules, syllabi, ECZ past papers — see
/// [CdcResourcesService]) has resources the teacher hasn't seen yet,
/// without requiring them to already be inside "Teaching Modules,
/// Syllabi & Past Papers" to notice. Renders nothing (zero height) when
/// there's nothing new to announce — never an empty card taking up space.
///
/// Triggers [CdcResourcesService.refreshIfDue] itself on load (same
/// weekly-throttled, online-only check every other entry point already
/// uses) so a teacher who never happens to open the resources screen
/// directly still gets a real, periodic check purely from opening the
/// app — this is what makes "notify users of new materials" true
/// app-wide rather than only reactive to a manual visit.
class CdcNewMaterialsBanner extends StatefulWidget {
  const CdcNewMaterialsBanner({super.key, this.service});

  final CdcResourcesService? service;

  @override
  State<CdcNewMaterialsBanner> createState() => _CdcNewMaterialsBannerState();
}

class _CdcNewMaterialsBannerState extends State<CdcNewMaterialsBanner> {
  late final CdcResourcesService _service = widget.service ?? CdcResourcesService();
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Opportunistic and silent — a failed/offline refresh just means this
    // check falls back to whatever's already cached (possibly zero), the
    // same "no error surfaced here" contract CdcResourcesScreen already
    // has for its own background refresh.
    try {
      await _service.refreshIfDue();
    } catch (_) {
      // Ignored — see this method's own doc comment.
    }
    final count = await _service.unseenCount();
    if (!mounted) return;
    setState(() => _count = count);
  }

  Future<void> _open() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TeachingResourcesMenuScreen(service: _service)),
    );
    final count = await _service.unseenCount();
    if (!mounted) return;
    setState(() => _count = count);
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: colorScheme.tertiaryContainer,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _open,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.new_releases_outlined, color: colorScheme.onTertiaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$_count new CDC resource${_count == 1 ? '' : 's'} available — Teaching Modules, '
                  'syllabi, and/or past papers ready to download.',
                  style: TextStyle(color: colorScheme.onTertiaryContainer),
                ),
              ),
              Icon(Icons.chevron_right, color: colorScheme.onTertiaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}
