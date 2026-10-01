/// OBC rationale (2026-09-26, per explicit request): at most three points,
/// and no action word repeated across them.
const kRationaleMaxPoints = 3;

/// At least this many points (2026-09-27, per explicit request: "at least
/// 2-3 distinct points ... not a single paragraph"). Only reachable when
/// [rationalePoints]'s `topUp` genuinely has enough real material — an entry
/// with truly nothing else to draw on (e.g. the syllabus's very first,
/// solitary sub-topic) can still fall short, since nothing is invented to
/// pad it artificially.
const kRationaleMinPoints = 2;

/// Alternative action words, grouped by meaning. A point whose leading action
/// word was already used earlier in the list is re-worded with the first
/// unused member of a group containing it; a verb outside every group is left
/// exactly as the syllabus wrote it. Members may be phrases ("carry out").
const _actionWordGroups = [
  ['describe', 'outline', 'explain', 'illustrate'],
  ['explain', 'clarify', 'account for', 'justify'],
  ['identify', 'recognise', 'name', 'pinpoint'],
  ['state', 'list', 'mention'],
  ['discuss', 'examine', 'explore'],
  ['analyse', 'analyze', 'examine', 'investigate'],
  ['calculate', 'compute', 'work out'],
  ['solve', 'work out', 'resolve'],
  ['use', 'apply', 'employ'],
  ['demonstrate', 'show', 'display', 'illustrate'],
  ['draw', 'sketch', 'construct'],
  ['construct', 'build', 'draw up'],
  ['classify', 'categorise', 'group'],
  ['compare', 'contrast', 'relate'],
  ['evaluate', 'assess', 'judge'],
  ['predict', 'forecast', 'anticipate'],
  ['measure', 'determine', 'find'],
  ['determine', 'find', 'establish'],
  ['define', 'state the meaning of', 'give the meaning of'],
  ['write', 'compose', 'record'],
  ['understand', 'grasp', 'appreciate'],
  ['distinguish', 'differentiate', 'tell apart'],
  ['relate', 'link', 'connect'],
  ['investigate', 'explore', 'examine'],
  ['prepare', 'draw up', 'put together'],
  ['give', 'provide', 'offer'],
  ['locate', 'find', 'pinpoint'],
  ['suggest', 'propose', 'recommend'],
  ['carry out', 'perform', 'conduct'],
  ['practice', 'rehearse', 'apply'],
  ['interpret', 'read', 'make sense of'],
  ['formulate', 'develop', 'devise'],
  ['simplify', 'reduce', 'work out'],
  ['establish', 'determine', 'confirm'],
  ['design', 'plan', 'devise'],
  ['choose', 'select', 'pick'],
  ['make', 'produce', 'create'],
  ['deduce', 'infer', 'conclude'],
  ['verify', 'confirm', 'check'],
  ['estimate', 'approximate', 'work out'],
];

Iterable<String> get _allMembers => _actionWordGroups.expand((g) => g);

/// The action word (or known multi-word phrase) a point opens with.
String _leadingVerb(String point) {
  final lower = point.trim().toLowerCase();
  String? best;
  for (final member in _allMembers) {
    if ((lower == member || lower.startsWith('$member ')) && (best == null || member.length > best.length)) {
      best = member;
    }
  }
  return best ?? lower.split(RegExp(r'\s+')).first.replaceAll(RegExp(r'[^a-z]'), '');
}

String _capitalise(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Rewrites repeated leading action words in [points] so each point opens
/// with a different one wherever a same-meaning alternative exists.
List<String> varyActionWords(List<String> points) {
  String firstOf(String p) => p.trim().toLowerCase().split(RegExp(r'\s+')).first.replaceAll(RegExp(r'[^a-z]'), '');
  final usedFirst = <String>{};
  final out = <String>[];
  for (final point in points) {
    var current = point.trim();
    if (usedFirst.contains(firstOf(current))) {
      final verb = _leadingVerb(current);
      final alternatives = [
        for (final group in _actionWordGroups)
          if (group.contains(verb)) ...group.where((w) => w != verb),
      ];
      final replacement = alternatives.firstWhere(
        (w) => !usedFirst.contains(w.split(' ').first),
        orElse: () => '',
      );
      if (replacement.isNotEmpty) {
        current = '${_capitalise(replacement)}${current.substring(verb.length)}';
      }
    }
    usedFirst.add(firstOf(current));
    out.add(current);
  }
  return out;
}

/// Up to [kRationaleMaxPoints] of [outcomes], preferring ones with different
/// leading verbs, order preserved, then re-worded by [varyActionWords].
///
/// [topUp] (2026-09-27, per explicit request: "at least 2-3 distinct
/// points") — more real syllabus outcomes/competencies FOR THE SAME TOPIC to
/// draw on only when [outcomes] alone give fewer than [kRationaleMinPoints]
/// (e.g. this sub-topic has just one competency, but a sibling sub-topic
/// under the same topic has more) — never used when [outcomes] alone
/// already reach the minimum, so a genuinely rich sub-topic is untouched.
List<String> rationalePoints(List<String> outcomes, {List<String> topUp = const []}) {
  final wanted = <int>[];
  final verbs = <String>{};
  for (var i = 0; i < outcomes.length && wanted.length < kRationaleMaxPoints; i++) {
    if (verbs.add(outcomes[i].trim().toLowerCase().split(RegExp(r'\s+')).first)) wanted.add(i);
  }
  for (var i = 0; i < outcomes.length && wanted.length < kRationaleMaxPoints; i++) {
    if (!wanted.contains(i)) wanted.add(i);
  }
  wanted.sort();
  final selected = [for (final i in wanted) outcomes[i]];

  if (selected.length < kRationaleMinPoints) {
    final seen = {for (final s in selected) s.trim().toLowerCase()};
    for (final candidate in topUp) {
      if (selected.length >= kRationaleMaxPoints) break;
      final key = candidate.trim().toLowerCase();
      if (!seen.add(key)) continue;
      selected.add(candidate);
      if (selected.length >= kRationaleMinPoints) break;
    }
  }
  return varyActionWords(selected);
}

/// The full rationale text for an OBC lesson, or null when there are no
/// outcomes to build it from. See [rationalePoints] for [topUp].
String? buildObcRationale(List<String> outcomes, {List<String> topUp = const []}) {
  final points = rationalePoints(outcomes, topUp: topUp);
  if (points.isEmpty) return null;
  return 'This lesson matters because, by the end of it, learners will be able to:\n'
      '${points.map((p) => '•  $p').join('\n')}';
}
