import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Sugo Library Stage 1 (owner request, 2026-09-29) — a stable content-
/// version hash for one topic, computed from whatever real source text it
/// was actually built from: an embedded lesson plan's own content, a
/// Subject Content Database/pamphlet excerpt, and/or the syllabus's own
/// real competencies/objectives — NEVER from the generated notes
/// themselves, so the hash only changes when the real underlying source
/// changes, not when wording is merely re-phrased on a re-run.
///
/// [sourceParts] should be passed in a stable order (the batch generator
/// always builds it the same way for the same topic) — this function does
/// not sort them, so callers own keeping that order deterministic.
/// Pure/offline: used identically by the Stage 2 batch generator (to decide
/// whether a topic actually needs regenerating) and, later, could be used
/// client-side to verify a downloaded topic against the manifest.
String sugoLibraryContentVersion(List<String> sourceParts) {
  final normalized = sourceParts.map((s) => s.trim()).where((s) => s.isNotEmpty).join('\u0000');
  final digest = sha256.convert(utf8.encode(normalized));
  // Truncated to 16 hex chars (64 bits) — plenty for change detection
  // (this is a version fingerprint, not a security hash), keeps the
  // manifest doc small across ~650 topics.
  return digest.toString().substring(0, 16);
}
