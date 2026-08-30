import 'package:flutter/material.dart';

/// Admin Tools — Minutes Maker. Placeholder for Stages 4-8 (offline
/// capture of handwritten meeting notes, AI reconstruction into a
/// professional minutes document, the 4-ad gate, unified progress, and
/// Word/PDF export) — the nav entry (Stage 1) and Admin Tools section
/// ship now; the feature itself is a follow-up build.
class MinutesMakerScreen extends StatelessWidget {
  const MinutesMakerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Minutes Maker')),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.groups_outlined, size: 64),
              SizedBox(height: 16),
              Text(
                'Minutes Maker is coming soon — photograph handwritten meeting notes and get back a '
                'professionally formatted minutes document.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
