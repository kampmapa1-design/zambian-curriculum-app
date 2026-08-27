/// One slide: a title plus its bullet points (empty for a pure title slide).
class Slide {
  final String title;
  final List<String> bullets;

  const Slide({required this.title, this.bullets = const []});
}

/// A full slide deck outline — the app-level intermediate form that both the
/// offline composer and the AI-enhanced path produce, before
/// [PptxDocumentService] turns it into an actual .pptx file.
class SlideOutline {
  final String deckTitle;
  final List<Slide> slides;

  const SlideOutline({required this.deckTitle, required this.slides});
}
