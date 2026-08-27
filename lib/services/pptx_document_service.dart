import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/slide_outline.dart';

/// Turns a [SlideOutline] into a real, openable .pptx file — entirely
/// on-device, no network. Hand-built minimal OOXML package (same technique
/// as [LessonPlanDocumentService]'s .docx output, extended to the
/// presentation part types): one slide master, one slide layout, one theme,
/// and one slide part per [Slide]. PowerPoint, LibreOffice Impress, and
/// Google Slides all open this minimal part set.
class PptxDocumentService {
  Future<File> generate(SlideOutline outline) async {
    final archive = Archive();
    void addXml(String name, String xml) {
      final bytes = utf8.encode(xml);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    final slideCount = outline.slides.length;

    addXml('[Content_Types].xml', _contentTypesXml(slideCount));
    addXml('_rels/.rels', _packageRelsXml);
    addXml('docProps/core.xml', _corePropsXml(outline.deckTitle));
    addXml('docProps/app.xml', _appPropsXml);
    addXml('ppt/presentation.xml', _presentationXml(slideCount));
    addXml('ppt/_rels/presentation.xml.rels', _presentationRelsXml(slideCount));
    addXml('ppt/slideMasters/slideMaster1.xml', _slideMasterXml);
    addXml('ppt/slideMasters/_rels/slideMaster1.xml.rels', _slideMasterRelsXml);
    addXml('ppt/slideLayouts/slideLayout1.xml', _slideLayoutXml);
    addXml('ppt/slideLayouts/_rels/slideLayout1.xml.rels', _slideLayoutRelsXml);
    addXml('ppt/theme/theme1.xml', _themeXml);
    for (var i = 0; i < slideCount; i++) {
      addXml('ppt/slides/slide${i + 1}.xml', _slideXml(outline.slides[i]));
      addXml('ppt/slides/_rels/slide${i + 1}.xml.rels', _slideRelsXml);
    }

    final zipped = ZipEncoder().encode(archive);
    final dir = await getTemporaryDirectory();
    final safeTitle =
        outline.deckTitle.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    final path = p.join(dir.path, '${safeTitle.isEmpty ? 'slides' : safeTitle}.pptx');
    final file = File(path);
    await file.writeAsBytes(zipped, flush: true);
    return file;
  }

  String _xmlEscape(String input) => input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  // 16:9 widescreen, in EMUs (914400 EMU = 1 inch).
  static const _slideWidth = 12192000;
  static const _slideHeight = 6858000;

  String _contentTypesXml(int slideCount) {
    final overrides = StringBuffer();
    for (var i = 1; i <= slideCount; i++) {
      overrides.write(
        '<Override PartName="/ppt/slides/slide$i.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>',
      );
    }
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/ppt/presentation.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
        '<Override PartName="/ppt/slideMasters/slideMaster1.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
        '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
        '<Override PartName="/ppt/theme/theme1.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
        '$overrides'
        '<Override PartName="/docProps/core.xml" '
        'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '<Override PartName="/docProps/app.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>'
        '</Types>';
  }

  static const _packageRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" '
      'Target="ppt/presentation.xml"/>'
      '<Relationship Id="rId2" '
      'Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" '
      'Target="docProps/core.xml"/>'
      '<Relationship Id="rId3" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" '
      'Target="docProps/app.xml"/>'
      '</Relationships>';

  String _corePropsXml(String title) => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<cp:coreProperties '
      'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>${_xmlEscape(title)}</dc:title>'
      '<dc:creator>Smart Teacher</dc:creator>'
      '</cp:coreProperties>';

  static const _appPropsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">'
      '<Application>Smart Teacher</Application>'
      '</Properties>';

  String _presentationXml(int slideCount) {
    final sldIds = StringBuffer();
    for (var i = 1; i <= slideCount; i++) {
      sldIds.write('<p:sldId id="${255 + i}" r:id="rIdSlide$i"/>');
    }
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
        '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rIdMaster1"/></p:sldMasterIdLst>'
        '<p:sldIdLst>$sldIds</p:sldIdLst>'
        '<p:sldSz cx="$_slideWidth" cy="$_slideHeight" type="screen16x9"/>'
        '<p:notesSz cx="$_slideHeight" cy="$_slideWidth"/>'
        '</p:presentation>';
  }

  String _presentationRelsXml(int slideCount) {
    final rels = StringBuffer();
    for (var i = 1; i <= slideCount; i++) {
      rels.write(
        '<Relationship Id="rIdSlide$i" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" '
        'Target="slides/slide$i.xml"/>',
      );
    }
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rIdMaster1" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" '
        'Target="slideMasters/slideMaster1.xml"/>'
        '$rels'
        '</Relationships>';
  }

  static const _slideMasterXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
      '<p:cSld><p:spTree>'
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
      '<p:grpSpPr/>'
      '</p:spTree></p:cSld>'
      '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" '
      'accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" '
      'folHlink="folHlink"/>'
      '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>'
      '</p:sldMaster>';

  static const _slideMasterRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" '
      'Target="../slideLayouts/slideLayout1.xml"/>'
      '<Relationship Id="rId2" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" '
      'Target="../theme/theme1.xml"/>'
      '</Relationships>';

  static const _slideLayoutXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="title" preserve="1">'
      '<p:cSld name="Title and Content"><p:spTree>'
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
      '<p:grpSpPr/>'
      '</p:spTree></p:cSld>'
      '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>'
      '</p:sldLayout>';

  static const _slideLayoutRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" '
      'Target="../slideMasters/slideMaster1.xml"/>'
      '</Relationships>';

  static const _slideRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" '
      'Target="../slideLayouts/slideLayout1.xml"/>'
      '</Relationships>';

  // Minimal Office-default theme — PowerPoint expects a reasonably complete
  // theme part (color/font/format schemes) even when slides set explicit
  // formatting and don't rely on inheritance.
  static const _themeXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Smart Teacher">'
      '<a:themeElements>'
      '<a:clrScheme name="Smart Teacher">'
      '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>'
      '<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
      '<a:dk2><a:srgbClr val="1565C0"/></a:dk2>'
      '<a:lt2><a:srgbClr val="E3F2FD"/></a:lt2>'
      '<a:accent1><a:srgbClr val="1565C0"/></a:accent1>'
      '<a:accent2><a:srgbClr val="0D47A1"/></a:accent2>'
      '<a:accent3><a:srgbClr val="42A5F5"/></a:accent3>'
      '<a:accent4><a:srgbClr val="90CAF9"/></a:accent4>'
      '<a:accent5><a:srgbClr val="1976D2"/></a:accent5>'
      '<a:accent6><a:srgbClr val="64B5F6"/></a:accent6>'
      '<a:hlink><a:srgbClr val="0563C1"/></a:hlink>'
      '<a:folHlink><a:srgbClr val="954F72"/></a:folHlink>'
      '</a:clrScheme>'
      '<a:fontScheme name="Smart Teacher">'
      '<a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
      '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>'
      '</a:fontScheme>'
      '<a:fmtScheme name="Smart Teacher">'
      '<a:fillStyleLst>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '</a:fillStyleLst>'
      '<a:lnStyleLst>'
      '<a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '<a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '<a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '</a:lnStyleLst>'
      '<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle>'
      '<a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle>'
      '</a:effectStyleLst>'
      '<a:bgFillStyleLst>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '</a:bgFillStyleLst>'
      '</a:fmtScheme>'
      '</a:themeElements>'
      '</a:theme>';

  String _slideXml(Slide slide) {
    const titleMargin = 457200;
    const titleY = 274638;
    const titleWidth = _slideWidth - (titleMargin * 2);
    const titleHeight = 1143000;
    const bodyY = titleY + titleHeight + 182562;
    const bodyHeight = _slideHeight - bodyY - 274638;

    final bulletParagraphs = StringBuffer();
    for (final bullet in slide.bullets) {
      bulletParagraphs.write(
        '<a:p><a:pPr marL="285750" indent="-285750">'
        '<a:buFont typeface="Arial"/><a:buChar char="•"/></a:pPr>'
        '<a:r><a:rPr lang="en-US" sz="2000" dirty="0"/><a:t>${_xmlEscape(bullet)}</a:t></a:r></a:p>',
      );
    }
    if (bulletParagraphs.isEmpty) {
      bulletParagraphs.write('<a:p><a:endParaRPr lang="en-US"/></a:p>');
    }

    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
        'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
        '<p:cSld><p:spTree>'
        '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr/>'
        '<p:sp>'
        '<p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
        '<p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>'
        '<p:spPr><a:xfrm><a:off x="$titleMargin" y="$titleY"/><a:ext cx="$titleWidth" cy="$titleHeight"/></a:xfrm></p:spPr>'
        '<p:txBody><a:bodyPr/><a:lstStyle/>'
        '<a:p><a:r><a:rPr lang="en-US" sz="3200" b="1" dirty="0"/><a:t>${_xmlEscape(slide.title)}</a:t></a:r></a:p>'
        '</p:txBody></p:sp>'
        '<p:sp>'
        '<p:nvSpPr><p:cNvPr id="3" name="Body"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
        '<p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr>'
        '<p:spPr><a:xfrm><a:off x="$titleMargin" y="$bodyY"/><a:ext cx="$titleWidth" cy="$bodyHeight"/></a:xfrm></p:spPr>'
        '<p:txBody><a:bodyPr/><a:lstStyle/>'
        '$bulletParagraphs'
        '</p:txBody></p:sp>'
        '</p:spTree></p:cSld>'
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>'
        '</p:sld>';
  }
}
