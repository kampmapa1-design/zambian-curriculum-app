/// One entry in the CDC Digital Library catalog (a Teaching Module, syllabus,
/// or similar document) — metadata only. See [CdcResourcesService] for how
/// the catalog is fetched and cached, and why the actual files aren't
/// bundled with the app.
class CdcResource {
  final String title;
  final String? subjectName;
  final String? level;
  final String? term;
  final String url;

  /// 'module' (a Teaching Module) or 'syllabus' — lets the CDC Resources
  /// screen split into separate "Teaching Modules" / "Syllabi" views rather
  /// than one mixed list. Older cached entries (fetched before this field
  /// existed) fall back to 'module', the more common case.
  final String resourceType;

  const CdcResource({
    required this.title,
    this.subjectName,
    this.level,
    this.term,
    required this.url,
    this.resourceType = 'module',
  });

  factory CdcResource.fromJson(Map<String, dynamic> json) => CdcResource(
        title: json['title'] as String,
        subjectName: json['subjectName'] as String?,
        level: json['level'] as String?,
        term: json['term'] as String?,
        url: json['url'] as String,
        resourceType: json['resourceType'] as String? ?? 'module',
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'subjectName': subjectName,
        'level': level,
        'term': term,
        'url': url,
        'resourceType': resourceType,
      };
}

/// The locally cached catalog: every resource known so far, and when it was
/// last successfully refreshed from the CDC site.
class CdcCatalog {
  final List<CdcResource> resources;
  final DateTime fetchedAt;

  const CdcCatalog({required this.resources, required this.fetchedAt});

  factory CdcCatalog.empty() =>
      CdcCatalog(resources: const [], fetchedAt: DateTime.fromMillisecondsSinceEpoch(0));

  factory CdcCatalog.fromJson(Map<String, dynamic> json) => CdcCatalog(
        resources: (json['resources'] as List)
            .cast<Map<String, dynamic>>()
            .map(CdcResource.fromJson)
            .toList(),
        fetchedAt: DateTime.parse(json['fetchedAt'] as String),
      );

  Map<String, dynamic> toJson() => {
        'resources': resources.map((r) => r.toJson()).toList(),
        'fetchedAt': fetchedAt.toIso8601String(),
      };
}
