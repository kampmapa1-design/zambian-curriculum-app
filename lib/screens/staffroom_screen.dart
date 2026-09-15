import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../models/school.dart';
import '../services/school_service.dart';
import '../services/staffroom_service.dart';

/// Stage 10 of School Network (added 2026-09-13) — "Staffroom", separate
/// from the report-form workflow. Any member can post; Head Teacher/
/// Deputy/Administrator can pin or remove any post (moderation, required
/// from launch per the brief, not optional).
class StaffroomScreen extends StatefulWidget {
  const StaffroomScreen({required this.school, super.key});
  final School school;

  @override
  State<StaffroomScreen> createState() => _StaffroomScreenState();
}

class _StaffroomScreenState extends State<StaffroomScreen> {
  final _staffroomService = StaffroomService();
  final _schoolService = SchoolService();
  String? _topicFilter; // null = all topics
  SchoolRole? _myRole;
  String _myName = '';

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final claim = await _schoolService.currentSchoolClaim();
    String name = '';
    if (uid != null) {
      final member = await _schoolService.getMember(widget.school.id, uid);
      name = member?.name ?? '';
    }
    if (!mounted) return;
    setState(() {
      _myRole = claim.role;
      _myName = name;
    });
  }

  bool get _isModerator => _myRole?.isLeadership == true || _myRole == SchoolRole.administrator;

  Future<void> _compose() async {
    final textController = TextEditingController();
    final topicController = TextEditingController(text: _topicFilter ?? 'General');
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New post'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: topicController,
              decoration: const InputDecoration(labelText: 'Topic', hintText: 'General, Staff Meeting Notes, ...', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Message', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Post')),
        ],
      ),
    );
    if (result != true || textController.text.trim().isEmpty) return;
    await _staffroomService.post(
      schoolId: widget.school.id,
      text: textController.text,
      topic: topicController.text,
      authorName: _myName,
    );
  }

  Future<void> _confirmDelete(StaffroomPost post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete post?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      await _staffroomService.deletePost(widget.school.id, post.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('Staffroom')),
      body: StreamBuilder<List<StaffroomPost>>(
        stream: _staffroomService.watchPosts(widget.school.id, topic: _topicFilter),
        builder: (context, snapshot) {
          final posts = snapshot.data ?? const [];
          final topics = <String>{'General', ...posts.map((p) => p.topic)}.toList()..sort();
          return Column(
            children: [
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(label: const Text('All'), selected: _topicFilter == null, onSelected: (_) => setState(() => _topicFilter = null)),
                    ),
                    for (final topic in topics)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(label: Text(topic), selected: _topicFilter == topic, onSelected: (_) => setState(() => _topicFilter = topic)),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: !snapshot.hasData
                    ? const Center(child: CircularProgressIndicator())
                    : posts.isEmpty
                        ? const Center(child: Text('No posts yet — be the first to say something.'))
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: posts.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final post = posts[index];
                              final canModerate = _isModerator || post.authorUid == uid;
                              return Card(
                                color: post.pinned ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35) : null,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          if (post.pinned) const Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.push_pin, size: 14)),
                                          Expanded(
                                            child: Text(post.authorName, style: const TextStyle(fontWeight: FontWeight.bold)),
                                          ),
                                          Chip(label: Text(post.topic, style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(post.text),
                                      if (canModerate) ...[
                                        const SizedBox(height: 4),
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.end,
                                          children: [
                                            if (_isModerator)
                                              TextButton(
                                                onPressed: () => _staffroomService.setPinned(widget.school.id, post.id, !post.pinned),
                                                child: Text(post.pinned ? 'Unpin' : 'Pin'),
                                              ),
                                            TextButton(onPressed: () => _confirmDelete(post), child: const Text('Delete')),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(onPressed: _compose, child: const Icon(Icons.add)),
    );
  }
}
