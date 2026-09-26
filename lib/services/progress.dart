import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';

import 'library.dart';

// Reading progress is read back from the readers' own saved state:
// - EPUB: Calibre's viewer keeps a "last-read" CFI per book in
//   %APPDATA%\calibre\viewer\annots\<sha256(book path)>.json
// - PDF: PDFgear keeps a 0-based page index per file in its SQLite config DB.
// Neither format is documented, so everything here fails soft to null.

final _epubCache = <String, ({DateTime mtime, double? progress})>{};
final _pageCounts = <String, int>{};

/// Returns progress (0..1) for each book path that has any.
Future<Map<String, double>> readProgress(List<String> bookPaths) async {
  final result = <String, double>{};
  final pdfPages = await _pdfgearPages();
  for (final path in bookPaths) {
    final ext = p.extension(path).toLowerCase();
    double? progress;
    if (ext == '.epub') {
      progress = await _epubProgress(path);
    } else if (ext == '.pdf') {
      final page = pdfPages[path.toUpperCase()];
      if (page != null) {
        final count = await _pdfPageCount(path);
        if (count != null && count > 0) progress = ((page + 1) / count).clamp(0.0, 1.0);
      }
    }
    if (progress != null) result[path] = progress;
  }
  return result;
}

// ── Calibre / EPUB ────────────────────────────────────────────────────────────

File _calibreAnnotsFile(String bookPath) {
  final appData = Platform.environment['APPDATA'] ?? '';
  final key = sha256.convert(utf8.encode(bookPath)).toString();
  return File(p.join(appData, 'calibre', 'viewer', 'annots', '$key.json'));
}

Future<double?> _epubProgress(String bookPath) async {
  try {
    final annots = _calibreAnnotsFile(bookPath);
    if (!await annots.exists()) return null;
    final mtime = await annots.lastModified();
    final cached = _epubCache[bookPath];
    if (cached != null && cached.mtime == mtime) return cached.progress;

    final entries = (jsonDecode(await annots.readAsString()) as List).cast<Map<String, dynamic>>();
    final lastRead = entries.where((e) => e['type'] == 'last-read' && e['pos_type'] == 'epubcfi').toList()
      ..sort((a, b) => (a['timestamp'] as String).compareTo(b['timestamp'] as String));
    double? progress;
    if (lastRead.isNotEmpty) {
      final cfi = lastRead.last['pos'] as String;
      progress = await Isolate.run(() => epubCfiProgress(bookPath, cfi));
    }
    _epubCache[bookPath] = (mtime: mtime, progress: progress);
    return progress;
  } catch (_) {
    return null;
  }
}

/// Converts a Calibre viewer CFI like `epubcfi(/12/2/4/2[id]/14/1:433)` into a
/// fraction of the book's text. The first step picks the spine item
/// (step / 2 - 1); the rest walks that document from its root.
double? epubCfiProgress(String bookPath, String cfi) {
  final m = RegExp(r'^epubcfi\((.*)\)$').firstMatch(cfi);
  if (m == null) return null;
  final steps = _parseCfi(m.group(1)!);
  if (steps.isEmpty) return null;
  final spineIndex = steps.first.index ~/ 2 - 1;

  final archive = ZipDecoder().decodeBuffer(InputFileStream(bookPath));
  try {
    final spine = _spinePaths(archive);
    if (spineIndex < 0 || spineIndex >= spine.length) return null;

    final lengths = <int>[];
    XmlDocument? current;
    for (var i = 0; i < spine.length; i++) {
      final doc = _parseDoc(archive, spine[i]);
      if (i == spineIndex) current = doc;
      lengths.add(doc == null ? 0 : _textLength(_body(doc) ?? doc.rootElement));
    }
    final total = lengths.fold<int>(0, (a, b) => a + b);
    if (total == 0) return null;
    final before = lengths.take(spineIndex).fold<int>(0, (a, b) => a + b);
    final within = current == null ? 0 : _offsetInDoc(current, steps.skip(1).toList());
    return ((before + within.clamp(0, lengths[spineIndex])) / total).clamp(0.0, 1.0);
  } finally {
    archive.clearSync();
  }
}

typedef _CfiStep = ({int index, String? id, int? offset});

List<_CfiStep> _parseCfi(String path) {
  final steps = <_CfiStep>[];
  for (final m in RegExp(r'/(\d+)(?:\[([^\]]*)\])?(?::(\d+))?').allMatches(path)) {
    steps.add((
      index: int.parse(m.group(1)!),
      id: m.group(2),
      offset: m.group(3) == null ? null : int.parse(m.group(3)!),
    ));
  }
  return steps;
}

List<String> _spinePaths(Archive archive) {
  final container = archive.findFile('META-INF/container.xml');
  if (container == null) return [];
  final containerXml = XmlDocument.parse(utf8.decode(container.content as List<int>));
  final opfPath = containerXml.findAllElements('rootfile').first.getAttribute('full-path');
  if (opfPath == null) return [];
  final opfFile = archive.findFile(opfPath);
  if (opfFile == null) return [];
  final opf = XmlDocument.parse(utf8.decode(opfFile.content as List<int>));
  final opfDir = p.posix.dirname(opfPath);
  final manifest = {
    for (final item in opf.findAllElements('item'))
      item.getAttribute('id'): item.getAttribute('href'),
  };
  return [
    for (final ref in opf.findAllElements('itemref'))
      if (manifest[ref.getAttribute('idref')] case final href?)
        p.posix.normalize(p.posix.join(opfDir, Uri.decodeFull(href))),
  ];
}

XmlDocument? _parseDoc(Archive archive, String path) {
  try {
    final f = archive.findFile(path);
    if (f == null) return null;
    return XmlDocument.parse(utf8.decode(f.content as List<int>, allowMalformed: true));
  } catch (_) {
    return null;
  }
}

XmlElement? _body(XmlDocument doc) => doc.rootElement.childElements
    .where((e) => e.localName == 'body')
    .firstOrNull;

int _textLength(XmlNode node) {
  var n = 0;
  for (final t in node.descendants.whereType<XmlText>()) {
    if (t.value.trim().isNotEmpty) n += t.value.length;
  }
  return n;
}

/// Counts body text before the CFI position. Even steps are element children
/// (2 = first); odd steps are the text between them, with an optional :offset.
int _offsetInDoc(XmlDocument doc, List<_CfiStep> steps) {
  XmlNode node = doc;
  XmlNode? target;
  var extra = 0;
  for (final step in steps) {
    final elements = node.children.whereType<XmlElement>().toList();
    if (step.index.isEven) {
      final i = step.index ~/ 2 - 1;
      if (i < 0 || i >= elements.length) break;
      node = elements[i];
      target = node;
      extra = step.offset ?? 0;
    } else {
      // Text chunk after element (index - 1) / 2; start at the node following it.
      final i = (step.index - 1) ~/ 2;
      final after = i == 0 ? null : (i - 1 < elements.length ? elements[i - 1] : null);
      final idx = after == null ? 0 : node.children.indexOf(after) + 1;
      target = idx < node.children.length ? node.children[idx] : node;
      extra = step.offset ?? 0;
      break;
    }
  }
  if (target == null) return 0;

  final body = _body(doc);
  if (body == null) return 0;
  // Pointing at <body> itself (or above it) means the start of the chapter.
  if (identical(target, body) || body.ancestors.any((a) => identical(a, target))) return extra;
  if (!target.ancestors.any((a) => identical(a, body))) return 0;
  var n = 0;
  for (final d in body.descendants) {
    if (identical(d, target)) break;
    if (d is XmlText && d.value.trim().isNotEmpty) n += d.value.length;
  }
  return n + extra;
}

// ── PDFgear / PDF ─────────────────────────────────────────────────────────────

/// Uppercased full path -> 0-based page index.
Future<Map<String, int>> _pdfgearPages() async {
  final local = Platform.environment['LOCALAPPDATA'] ?? '';
  final dbFile = File(p.join(local, 'PDFgear', 'AppData', 'pdfdata.db'));
  if (!await dbFile.exists()) return {};
  final pages = <String, int>{};
  Database? db;
  try {
    db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    final rows = db.select("SELECT value FROM configs WHERE key = 'DocumentCurrentPageNumber'");
    if (rows.isEmpty) return {};
    final entries = (jsonDecode(rows.first['value'] as String) as List).cast<Map<String, dynamic>>();
    for (final e in entries) {
      var file = e['file'] as String?;
      final idx = (e['idx'] as num?)?.toInt();
      if (file == null || idx == null) continue;
      // PDFgear sometimes records 8.3 short names (BUILDA~1.PDF); resolve them.
      if (file.contains('~')) {
        try {
          file = await File(file).resolveSymbolicLinks();
        } catch (_) {
          continue;
        }
      }
      pages[file.toUpperCase()] = idx;
    }
  } catch (_) {
    return {};
  } finally {
    db?.close();
  }
  return pages;
}

Future<int?> _pdfPageCount(String path) async {
  final cached = _pageCounts[path];
  if (cached != null) return cached;
  PdfDocument? doc;
  try {
    doc = await openPdf(path);
    return _pageCounts[path] = doc.pages.length;
  } catch (_) {
    return null;
  } finally {
    await doc?.dispose();
  }
}
