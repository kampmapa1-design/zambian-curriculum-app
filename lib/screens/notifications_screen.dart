import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

/// Stage 6's in-app edit notifications (School Network, added
/// 2026-09-13) — "Entry of student [name] has been edited by [editor
/// name]." Read from `teacher_profiles/{uid}/notifications`, written only
/// by `submitClassScoreEntry` (see index.ts).
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return Scaffold(appBar: AppBar(title: const Text('Notifications')), body: const Center(child: Text('Sign in to see notifications.')));
    }
    final query = FirebaseFirestore.instance
        .collection('teacher_profiles')
        .doc(uid)
        .collection('notifications')
        .orderBy('createdAt', descending: true)
        .limit(100);

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: query.snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) return const Center(child: Text('No notifications yet.'));
          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data();
              final read = data['read'] as bool? ?? false;
              final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
              return ListTile(
                leading: Icon(read ? Icons.notifications_none : Icons.notifications_active, color: read ? null : Theme.of(context).colorScheme.primary),
                title: Text(
                  data['message'] as String? ?? '',
                  style: TextStyle(fontWeight: read ? FontWeight.normal : FontWeight.bold),
                ),
                subtitle: createdAt == null ? null : Text('${createdAt.toLocal()}'.split('.').first),
                onTap: read ? null : () => doc.reference.update({'read': true}),
              );
            },
          );
        },
      ),
    );
  }
}
