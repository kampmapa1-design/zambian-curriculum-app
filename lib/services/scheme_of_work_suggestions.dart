/// Rule-based starting-value suggestions for the Scheme of Work columns
/// that have no corresponding field anywhere in this app's bundled
/// syllabus data — Key Competences, Strategies & Methodologies, and TL
/// Aids & Materials. Previously these three columns (out of the CBC
/// template's 11) were left completely blank on every generated scheme,
/// regardless of subject or topic, which is what produced schemes that
/// looked like only two or three columns were ever filled in.
///
/// **What this deliberately is NOT**: a transcription of the CDC's own
/// published guidance. Research (2026-08-29) into Zambia's CBC framework
/// consistently named critical thinking, communication, collaboration,
/// creativity, problem solving, and digital literacy as the curriculum's
/// core competency themes across every source found, but no single
/// authoritative source gave a clean, citable, itemized official list
/// with exact phrasing — so these functions build a sensible, always-
/// editable *starting point* from well-established general pedagogy and
/// the syllabus's own topic text, not a claim of official CDC wording.
/// Every value produced here lands in a `suggested` column (see
/// SchemeOfWorkColumnDef), never `autoFilled` — a teacher reviews and
/// adjusts it like any other cell, exactly like Expected Standards
/// already works.
library;

/// The well-corroborated core CBC competency themes (see file doc for the
/// research this was grounded in) — kept as a fixed, small, reviewable
/// list rather than invented per-topic, so what appears in a scheme is
/// always one of these familiar phrases, not a fabricated one-off.
const _keyCompetenceThemes = <String, List<String>>{
  'Critical Thinking and Problem Solving': [
    'solve', 'calculate', 'analyse', 'analyze', 'evaluate', 'investigate', 'reason', 'deduce', 'compare',
    'why', 'how', 'determine', 'assess', 'diagnose', 'measure',
  ],
  'Communication and Collaboration': [
    'discuss', 'present', 'debate', 'explain to', 'group', 'share', 'communicate', 'role play', 'interview',
    'report', 'argue', 'persuade',
  ],
  'Creativity and Innovation': [
    'design', 'create', 'compose', 'invent', 'draw', 'construct', 'produce', 'develop a', 'model', 'craft',
  ],
  'Digital and ICT Literacy': [
    'computer', 'digital', 'ict', 'software', 'internet', 'online', 'spreadsheet', 'app', 'programme', 'code',
    'coding', 'database',
  ],
  'Self and Life Skills': [
    'practice', 'practise', 'apply', 'demonstrate', 'perform', 'exercise', 'routine', 'safety', 'hygiene',
    'care for',
  ],
};

/// Standard teaching methods, chosen by what the topic's own text hints
/// at doing — hands-on/practical, discussion-based, or a reasonable
/// general-purpose default. These are ordinary, widely-taught pedagogy
/// terms, not specific to any one document.
String suggestStrategiesMethodologies(String combinedText) {
  final text = combinedText.toLowerCase();
  final methods = <String>[];

  if (_containsAny(text, ['experiment', 'practical', 'demonstrat', 'apparatus', 'construct', 'build', 'draw'])) {
    methods.add('Demonstration and guided practical activity');
  }
  if (_containsAny(text, ['discuss', 'debate', 'group work', 'group', 'share ideas', 'brainstorm'])) {
    methods.add('Group discussion and question-and-answer');
  }
  if (_containsAny(text, ['read', 'passage', 'text', 'comprehension', 'story', 'poem', 'novel'])) {
    methods.add('Guided reading and class discussion');
  }
  if (_containsAny(text, ['role play', 'act out', 'dramat', 'simulate', 'scenario'])) {
    methods.add('Role play/simulation');
  }
  if (_containsAny(text, ['project', 'research', 'investigate', 'field'])) {
    methods.add('Project work/small-group investigation');
  }

  if (methods.isEmpty) {
    methods.add('Explanation, question-and-answer, and guided practice');
  }
  return methods.take(2).join('; ');
}

/// Standard, generic categories of teaching/learning materials, again
/// chosen by keyword hints rather than a fixed one-size-fits-all answer.
String suggestTlAidsMaterials(String combinedText) {
  final text = combinedText.toLowerCase();
  final aids = <String>[];

  if (_containsAny(text, ['experiment', 'practical', 'apparatus', 'chemical', 'specimen'])) {
    aids.add('Relevant apparatus/materials for the activity');
  }
  if (_containsAny(text, ['computer', 'digital', 'ict', 'software', 'internet', 'online'])) {
    aids.add('Computer/ICT device and relevant software or online resource');
  }
  if (_containsAny(text, ['map', 'diagram', 'chart', 'graph', 'illustrat'])) {
    aids.add('Charts/diagrams or maps');
  }
  if (_containsAny(text, ['calculate', 'measure', 'number', 'figure'])) {
    aids.add('Calculator/measuring instruments as relevant');
  }

  aids.add('Textbook and chalkboard/whiteboard');
  return aids.take(3).join('; ');
}

/// Picks up to two of the fixed [_keyCompetenceThemes] whose keywords
/// appear in the topic's own text, falling back to the two most
/// universally-applicable ones (critical thinking and communication) when
/// nothing more specific matches.
String suggestKeyCompetences(String combinedText) {
  final text = combinedText.toLowerCase();
  final matched = <String>[];
  for (final entry in _keyCompetenceThemes.entries) {
    if (_containsAny(text, entry.value)) matched.add(entry.key);
  }
  if (matched.isEmpty) {
    matched.addAll(['Critical Thinking and Problem Solving', 'Communication and Collaboration']);
  }
  return matched.take(2).join('; ');
}

bool _containsAny(String text, List<String> needles) => needles.any(text.contains);
