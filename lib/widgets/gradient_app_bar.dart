import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Stage C of the aesthetics pass — extends the home screen's branded
/// gradient header to this app's other major entry screens (Chief Marker,
/// Scheme of Work, Timetable, Report Form), so the app feels considered
/// throughout the journey rather than just at first launch. Deliberately a
/// drop-in [AppBar] replacement (same [PreferredSizeWidget] contract, same
/// `actions`) rather than converting each screen to a collapsing
/// [SliverAppBar] like the home screen's own header — several of these
/// screens have real state/overlay logic (selection mode, a score-pop
/// overlay, a bottom action bar) that a full Sliver/CustomScrollView
/// restructure risks disturbing for a purely visual change.
class GradientAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GradientAppBar({super.key, required this.title, this.actions, this.subtitle});

  final String title;
  final String? subtitle;
  final List<Widget>? actions;

  @override
  Size get preferredSize => Size.fromHeight(subtitle == null ? kToolbarHeight : kToolbarHeight + 14);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      // Stage I (gradients, 2026-09-27): the token version of this same
      // gradient (now 3 stops instead of 2) — see AppGradients.hero's own
      // doc comment; this widget already used the exact 2-stop version
      // that token was extracted from, so upgrading it here gives every
      // one of its 6 real screens the richer gradient for free.
      decoration: BoxDecoration(gradient: AppGradients.hero(colorScheme)),
      child: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: colorScheme.onPrimary,
        elevation: 0,
        title: subtitle == null
            ? Text(title)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title),
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onPrimary.withValues(alpha: 0.85),
                        ),
                  ),
                ],
              ),
        actions: actions,
      ),
    );
  }
}
