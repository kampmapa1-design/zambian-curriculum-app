import 'package:flutter/material.dart';

import '../models/marked_results_list.dart';
import '../services/marked_results_list_repository.dart';
import 'marked_results_list_detail_screen.dart';

/// Every manually-curated results list created from MarkedScriptsScreen's
/// select mode (added 2026-09-02) — see marked_results_list.dart for the
/// full model/lifecycle.
class MarkedResultsListsScreen extends StatefulWidget {
  const MarkedResultsListsScreen({super.key, this.listRepository});

  final MarkedResultsListRepository? listRepository;

  @override
  State<MarkedResultsListsScreen> createState() => _MarkedResultsListsScreenState();
}

class _MarkedResultsListsScreenState extends State<MarkedResultsListsScreen> {
  late final MarkedResultsListRepository _listRepository = widget.listRepository ?? MarkedResultsListRepository();

  bool _loading = true;
  List<MarkedResultsList> _lists = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final catalog = await _listRepository.loadCatalog();
    if (!mounted) return;
    setState(() {
      _lists = catalog.lists..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _loading = false;
    });
  }

  Future<void> _openList(MarkedResultsList list) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => MarkedResultsListDetailScreen(list: list, listRepository: _listRepository)),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Results Lists')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _lists.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.folder_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        const Text(
                          'No results lists yet — select scripts on "Marked Scripts" and tap "New List" to create one.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _lists.length,
                  itemBuilder: (context, index) {
                    final list = _lists[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: list.exported
                            ? Theme.of(context).colorScheme.errorContainer
                            : Theme.of(context).colorScheme.primaryContainer,
                        child: Icon(list.exported ? Icons.lock_outline : Icons.folder_outlined, size: 18),
                      ),
                      title: Text(list.name),
                      subtitle: Text(
                        '${list.scriptIds.length} script(s)'
                        '${list.exported ? ' · Exported/shared — scores locked' : ' · Scores still editable'}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openList(list),
                    );
                  },
                ),
    );
  }
}
