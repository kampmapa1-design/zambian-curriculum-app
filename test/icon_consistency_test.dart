// Aesthetics pass, Stage L (2026-09-27): consistent iconography. This app
// has no custom icon-asset pipeline (only assets/icon/icon.png, a single
// app-icon bitmap) — its real "mismatched icon styles" problem, verified by
// auditing every real `Icons.*` usage in lib/, was a MIX of Material's
// default/filled icons alongside its own established "_outlined" family
// (108 of 109 already-suffixed uses were "_outlined", just one stray
// "_rounded", zero "_sharp"). The fix (2026-09-27): every plain icon name
// that has a real "_outlined" sibling in the Flutter SDK's own icon set was
// mechanically converted (204 replacements across 90 files, verified
// against the SDK's actual icons.dart so no invented identifier could slip
// through) — a REAL bug this same process caught and fixed: several names
// already ending in the legacy singular "_outline" (e.g. "check_circle_
// outline", "delete_outline" — an older Material naming convention,
// already outlined-style) were wrongly matched too, producing invalid
// double-suffixed names like "check_circle_outline_outlined"; reverted.
//
// This test is the ongoing guard: any FUTURE bare (non-"_outlined"/
// "_rounded"/"_sharp") icon name introduced anywhere in lib/ must be one of
// the two allowed exceptions below, not a fresh inconsistency.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Legacy Material icon names already ending in the OLDER singular
/// "_outline" (no "d") — these ARE the outlined-style icon, under an older
/// naming convention; there is no separate "_outlined"-suffixed sibling to
/// convert to (or, if the SDK does define one, it is a MEANINGFULLY
/// DIFFERENT glyph, e.g. how `check_circle_outline` and a hypothetical
/// `check_circle_outlined` are not interchangeable) — never touch these.
const kLegacyOutlineIconNames = {
  'add_circle_outline',
  'chat_bubble_outline',
  'check_circle_outline',
  'delete_outline',
  'error_outline',
  'info_outline',
  'lock_outline',
  'person_outline',
  'play_circle_outline',
};

/// Icons confirmed to have NO real "_outlined" sibling in the Flutter SDK's
/// icon set at all (a single-style glyph) — fine to use bare.
const kSingleStyleIconNames = {
  'edit_document',
};

final _iconUsage = RegExp(r'Icons\.([a-zA-Z0-9_]+)');
final _suffixed = RegExp(r'_(outlined|rounded|sharp)$');

Set<String> _bareIconNamesIn(Directory dir) {
  final names = <String>{};
  for (final entry in dir.listSync(recursive: true)) {
    if (entry is! File || !entry.path.endsWith('.dart')) continue;
    for (final match in _iconUsage.allMatches(entry.readAsStringSync())) {
      final name = match.group(1)!;
      if (!_suffixed.hasMatch(name)) names.add(name);
    }
  }
  return names;
}

void main() {
  test('every bare (non-suffixed) Icons.* usage in lib/ is a confirmed, allowed exception', () {
    final bare = _bareIconNamesIn(Directory('lib'));
    final allowed = {...kLegacyOutlineIconNames, ...kSingleStyleIconNames};
    final unexpected = bare.difference(allowed);
    expect(unexpected, isEmpty,
        reason: 'these icon(s) are neither an established "_outlined"/"_rounded"/"_sharp" name nor a confirmed '
            'exception — check whether a real "_outlined" sibling exists and convert to it: $unexpected');
  });

  test('no accidental double-suffix ever slipped back in (the exact bug this stage caught once)', () {
    final all = <String>{};
    for (final entry in Directory('lib').listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) continue;
      for (final match in _iconUsage.allMatches(entry.readAsStringSync())) {
        all.add(match.group(1)!);
      }
    }
    final doubled = all.where((n) => RegExp(r'_outline_outlined$|_outlined_outlined$|_rounded_outlined$').hasMatch(n));
    expect(doubled, isEmpty);
  });

  test('the app-wide convention really is "_outlined", not a mix — at least 100 real uses, and none "_sharp"', () {
    final all = <String>{};
    var outlinedCount = 0;
    for (final entry in Directory('lib').listSync(recursive: true)) {
      if (entry is! File || !entry.path.endsWith('.dart')) continue;
      for (final match in _iconUsage.allMatches(entry.readAsStringSync())) {
        final name = match.group(1)!;
        all.add(name);
        if (name.endsWith('_outlined')) outlinedCount++;
      }
    }
    expect(outlinedCount, greaterThan(100));
    expect(all.where((n) => n.endsWith('_sharp')), isEmpty, reason: '"_sharp" would be a third, mismatched style family');
  });
}
