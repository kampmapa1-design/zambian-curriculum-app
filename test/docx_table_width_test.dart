// Regression test for pdf_manipulator issue #243 (fixed in 5.0.0, which the
// Word/PDF converter screen relies on): rebuilds the synthetic repro
// (11-column landscape DOCX table, declared widths ~10.3in on a 10in
// printable width) and checks the converted PDF keeps every text run inside
// the page.
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_manipulator/io.dart';
import 'package:pdf_manipulator/pdf_manipulator.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

const _cols = [666, 1330, 1237, 1401, 1258, 1236, 2160, 1440, 1260, 1440, 1368];

List<int> _buildDocx() {
  final grid = _cols.map((w) => '<w:gridCol w:w="$w"/>').join();
  final cells = StringBuffer();
  for (var r = 0; r < 3; r++) {
    cells.write('<w:tr>');
    for (var c = 0; c < _cols.length; c++) {
      cells.write('<w:tc><w:tcPr><w:tcW w:w="${_cols[c]}" w:type="dxa"/></w:tcPr><w:p><w:r><w:t>'
          'Row $r column $c ordinary body text that wraps within its cell</w:t></w:r></w:p></w:tc>');
    }
    cells.write('</w:tr>');
  }
  final document = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
      '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblLayout w:type="fixed"/></w:tblPr>'
      '<w:tblGrid>$grid</w:tblGrid>$cells</w:tbl>'
      '<w:sectPr><w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>'
      '<w:pgMar w:top="720" w:right="630" w:bottom="810" w:left="810" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>'
      '</w:body></w:document>';
  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>'))
    ..addFile(ArchiveFile.string('_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'))
    ..addFile(ArchiveFile.string('word/document.xml', document));
  return ZipEncoder().encode(archive);
}

void main() {
  test('DOCX table converts within the page (issue #243 regression check)', () async {
    final dir = Directory.systemTemp.createTempSync('docx_width_');
    final input = File('${dir.path}/table.docx')..writeAsBytesSync(_buildDocx());
    final output = File('${dir.path}/table.pdf');

    final pdf = Pdf();
    final sink = await FileSink.create(output);
    await pdf.convertToPdf(FileSource(input), sink, format: PdfDocumentFormat.docx);
    await sink.close();

    final doc = PdfDocument(inputBytes: output.readAsBytesSync());
    final pageWidth = doc.pages[0].size.width;
    final lines = PdfTextExtractor(doc).extractTextLines();
    var maxRight = 0.0;
    for (final line in lines) {
      if (line.bounds.right > maxRight) maxRight = line.bounds.right;
    }
    doc.dispose();
    // ignore: avoid_print
    print('TABLE_WIDTH_CHECK pageWidth=$pageWidth maxRight=$maxRight lines=${lines.length}');
    expect(lines, isNotEmpty);
    expect(maxRight, lessThanOrEqualTo(pageWidth + 1));
  }, timeout: const Timeout(Duration(minutes: 10)));
}
