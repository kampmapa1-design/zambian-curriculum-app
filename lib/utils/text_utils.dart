/// Trims [text] to at most [maxWords] words at a word boundary. Used to
/// enforce the 700-word cap on essay-format teaching notes — a safety net
/// for both the offline (syllabus-assembled) and AI-generated paths, since
/// AI output can occasionally run over despite the prompt's instruction.
String capWords(String text, int maxWords, {String? trailingNote}) {
  final words = text.trim().split(RegExp(r'\s+'));
  if (words.length <= maxWords) return text;
  final truncated = '${words.take(maxWords).join(' ')}...';
  return trailingNote == null ? truncated : '$truncated\n\n$trailingNote';
}

/// Strips common Markdown syntax an AI model can slip into output despite a
/// plain-text instruction (`### Heading`, `**bold**`, `---` rules, code
/// fences) so exported documents read as plainly professional, not visibly
/// AI-generated. A regex-based best-effort, not a full Markdown parser —
/// applied as a safety net alongside (not instead of) telling the model not
/// to use Markdown in the first place. Run this on every AI-generated
/// string before it's shown or exported.
String stripMarkdownArtifacts(String text) {
  var result = text;

  // Code fences (```...```) — drop the fence lines, keep the content.
  result = result.replaceAll(RegExp(r'^\s*```\w*\s*$', multiLine: true), '');

  // Headings: "### Heading" -> "Heading".
  result = result.replaceAllMapped(
    RegExp(r'^ {0,3}#{1,6}\s+(.*)$', multiLine: true),
    (m) => m.group(1)!.trim(),
  );

  // Bold: **text** or __text__ -> text.
  result = result.replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!);
  result = result.replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m.group(1)!);

  // Italic: *text* or _text_ -> text (only mid-word-safe forms — a leading
  // word-boundary keeps "3 * 4" style expressions untouched).
  result = result.replaceAllMapped(RegExp(r'(?<![\w*])\*([^\s*][^*]*?)\*(?!\*)'), (m) => m.group(1)!);
  result = result.replaceAllMapped(RegExp(r'(?<![\w_])_([^\s_][^_]*?)_(?!_)'), (m) => m.group(1)!);

  // Horizontal rules: a line that's only ---, ***, or ___ (3+) -> removed.
  result = result.replaceAll(RegExp(r'^\s*([-*_])\1{2,}\s*$', multiLine: true), '');

  // Inline code: `text` -> text.
  result = result.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!);

  // Markdown list markers ("- " / "* " at line start) -> the app's own "• "
  // bullet style, so lists still read as lists rather than losing structure.
  result = result.replaceAllMapped(RegExp(r'^(\s*)[-*]\s+', multiLine: true), (m) => '${m.group(1)}• ');

  // Collapse blank lines left behind by removed heading/rule lines.
  result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  return result.trim();
}
