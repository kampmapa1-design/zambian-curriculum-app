import 'package:flutter/material.dart';

/// The app's standard "pick a major function" button — a full-width card
/// with a leading icon, title, subtitle, and trailing chevron. Extracted
/// (2026-09-02) from `home_screen.dart`'s private `_FunctionButton` so the
/// same styling is reusable on sub-menu screens (e.g.
/// TeachingResourcesMenuScreen, AssignmentsTestsMenuScreen) that group a
/// few related functions behind one home-screen entry point, keeping
/// every "pick a function" screen in this app visually consistent.
class FunctionButton extends StatelessWidget {
  const FunctionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ListTile(
            leading: CircleAvatar(
              radius: 22,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(icon, color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle),
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
      ),
    );
  }
}
