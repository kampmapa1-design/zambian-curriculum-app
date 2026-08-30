/// One entry physically stored on-device in the Subject Content Database —
/// the app's local reserve of downloaded CDC materials (Teaching Modules,
/// syllabi, etc.) it can draw on later without needing a fresh download,
/// see `SubjectContentRepository`.
///
/// Stored as extracted plain text, not the original PDF — a Teaching
/// Module's real curriculum content (skipping the front matter that names
/// real people) runs a few tens of KB as text against a PDF often 1-10+MB,
/// and text is what generation actually needs. [isLegacyPdf] marks an
/// item saved before this format existed, still holding a raw PDF file
/// pending conversion — see `SubjectContentRepository.migrateLegacyItems`.
///
/// AI extraction (Gemini, via `SubjectContentExtractionService`) is always
/// tried first and needs a live connection. [extractedOnDevice] marks an
/// item whose text instead came from the on-device fallback
/// (`OnDevicePdfTextExtractionService`, used when offline or the AI call
/// fails) — usable immediately, but flagged for a one-time AI re-extraction
/// pass the next time the app is online, since AI extraction is generally
/// cleaner (drops headers/footers/page numbers, OCRs scans).
class SubjectContentItem {
  final String title;
  final String subjectName;
  final String resourceType;
  final String sourceUrl;

  /// File name only (relative to the subject's own subdirectory) — not a
  /// full path, since the app documents directory itself can move between
  /// app versions/reinstalls.
  final String fileName;

  final DateTime downloadedAt;
  final int sizeBytes;
  final bool isLegacyPdf;
  final bool extractedOnDevice;

  const SubjectContentItem({
    required this.title,
    required this.subjectName,
    required this.resourceType,
    required this.sourceUrl,
    required this.fileName,
    required this.downloadedAt,
    required this.sizeBytes,
    this.isLegacyPdf = false,
    this.extractedOnDevice = false,
  });

  factory SubjectContentItem.fromJson(Map<String, dynamic> json) => SubjectContentItem(
        title: json['title'] as String,
        subjectName: json['subjectName'] as String,
        resourceType: json['resourceType'] as String,
        sourceUrl: json['sourceUrl'] as String,
        fileName: json['fileName'] as String,
        downloadedAt: DateTime.parse(json['downloadedAt'] as String),
        sizeBytes: json['sizeBytes'] as int,
        isLegacyPdf: json['isLegacyPdf'] as bool? ?? false,
        extractedOnDevice: json['extractedOnDevice'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'subjectName': subjectName,
        'resourceType': resourceType,
        'sourceUrl': sourceUrl,
        'fileName': fileName,
        'downloadedAt': downloadedAt.toIso8601String(),
        'sizeBytes': sizeBytes,
        'isLegacyPdf': isLegacyPdf,
        'extractedOnDevice': extractedOnDevice,
      };

  SubjectContentItem copyWith({
    String? fileName,
    int? sizeBytes,
    bool? isLegacyPdf,
    bool? extractedOnDevice,
  }) =>
      SubjectContentItem(
        title: title,
        subjectName: subjectName,
        resourceType: resourceType,
        sourceUrl: sourceUrl,
        fileName: fileName ?? this.fileName,
        downloadedAt: downloadedAt,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        isLegacyPdf: isLegacyPdf ?? this.isLegacyPdf,
        extractedOnDevice: extractedOnDevice ?? this.extractedOnDevice,
      );
}

class SubjectContentCatalog {
  final List<SubjectContentItem> items;

  const SubjectContentCatalog({required this.items});

  factory SubjectContentCatalog.empty() => const SubjectContentCatalog(items: []);

  factory SubjectContentCatalog.fromJson(Map<String, dynamic> json) => SubjectContentCatalog(
        items: (json['items'] as List).cast<Map<String, dynamic>>().map(SubjectContentItem.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'items': [for (final i in items) i.toJson()]};

  int get totalSizeBytes => items.fold(0, (sum, i) => sum + i.sizeBytes);

  Map<String, List<SubjectContentItem>> get bySubject {
    final grouped = <String, List<SubjectContentItem>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.subjectName, () => []).add(item);
    }
    return grouped;
  }
}
