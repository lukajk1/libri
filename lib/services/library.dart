import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

import '../models/book_entry.dart';

// ── Config ────────────────────────────────────────────────────────────────────

File get configFile {
  final roaming = Platform.environment['APPDATA'] ?? '.';
  return File(p.join(roaming, 'Libri', 'config.json'));
}

Future<String?> loadLibraryPath() async {
  try {
    final f = configFile;
    if (!await f.exists()) return null;
    final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return json['libraryPath'] as String?;
  } catch (_) {
    return null;
  }
}

Future<void> saveLibraryPath(String path) async {
  final f = configFile;
  await f.parent.create(recursive: true);
  await f.writeAsString(jsonEncode({'libraryPath': path}));
}

// ── Library JSON ──────────────────────────────────────────────────────────────

File libraryFile(String libraryPath) =>
    File(p.join(libraryPath, 'library.json'));

Future<List<Map<String, dynamic>>> readLibraryJson(String libraryPath) async {
  final f = libraryFile(libraryPath);
  if (!await f.exists()) return [];
  try {
    return (jsonDecode(await f.readAsString()) as List)
        .cast<Map<String, dynamic>>();
  } catch (_) {
    return [];
  }
}

Future<void> writeLibraryJson(String libraryPath, List<BookEntry> books) async {
  final f = libraryFile(libraryPath);
  final data = books.map((b) => {
    'path': b.storedPath,
    'status': b.status.name,
    'importedAt': b.importedAt,
    'statusChangedAt': b.statusChangedAt,
  }).toList();
  await f.writeAsString(jsonEncode(data));
}

// ── Books dir ─────────────────────────────────────────────────────────────────

Future<Directory> booksDir(String libraryPath) async {
  final dir = Directory(p.join(libraryPath, 'books'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

// ── Cover ─────────────────────────────────────────────────────────────────────

Future<Uint8List?> extractEpubCoverBytes(String bookPath) async {
  try {
    final archive = ZipDecoder().decodeBytes(await File(bookPath).readAsBytes());
    final container = archive.findFile('META-INF/container.xml');
    if (container == null) return null;
    final containerXml = XmlDocument.parse(utf8.decode(container.content as List<int>));
    final opfPath = containerXml.findAllElements('rootfile').first.getAttribute('full-path');
    if (opfPath == null) return null;
    final opfFile = archive.findFile(opfPath);
    if (opfFile == null) return null;
    final opfXml = XmlDocument.parse(utf8.decode(opfFile.content as List<int>));
    final opfDir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';

    String? coverId;
    for (final meta in opfXml.findAllElements('meta')) {
      if (meta.getAttribute('name')?.toLowerCase() == 'cover') {
        coverId = meta.getAttribute('content');
        break;
      }
    }

    String? coverHref;
    if (coverId != null) {
      for (final item in opfXml.findAllElements('item')) {
        if (item.getAttribute('id') == coverId) {
          coverHref = item.getAttribute('href');
          break;
        }
      }
    }
    if (coverHref == null) {
      for (final item in opfXml.findAllElements('item')) {
        final id = item.getAttribute('id')?.toLowerCase() ?? '';
        final href = item.getAttribute('href')?.toLowerCase() ?? '';
        final mt = item.getAttribute('media-type') ?? '';
        if (mt.startsWith('image/') && (id.contains('cover') || href.contains('cover'))) {
          coverHref = item.getAttribute('href');
          break;
        }
      }
    }

    if (coverHref == null) return null;
    final imageFile = archive.findFile('$opfDir$coverHref');
    if (imageFile == null) return null;
    return Uint8List.fromList(imageFile.content as List<int>);
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> extractPdfCoverBytes(String bookPath) async {
  PdfDocument? doc;
  try {
    doc = await PdfDocument.openFile(bookPath);
    final page = doc.pages.first;
    // Render at a fixed width so covers are sharp without being huge.
    const targetWidth = 600.0;
    final scale = targetWidth / page.width;
    final w = (page.width * scale).round();
    final h = (page.height * scale).round();
    final pdfImage = await page.render(
      width: w,
      height: h,
      fullWidth: w.toDouble(),
      fullHeight: h.toDouble(),
      backgroundColor: 0xffffffff,
    );
    if (pdfImage == null) return null;
    final img = await pdfImage.createImage();
    pdfImage.dispose();
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return byteData?.buffer.asUint8List();
  } catch (_) {
    return null;
  } finally {
    await doc?.dispose();
  }
}

Future<Uint8List?> loadCachedCover(String bookPath) async {
  final coverFile = File(p.join(p.dirname(bookPath), 'cover.jpg'));
  if (await coverFile.exists()) return coverFile.readAsBytes();
  return null;
}

// MOBI / AZW / AZW3 are PalmDB containers. Record 0 holds the MOBI header,
// which gives the index of the first image record, and an optional EXTH block
// whose record 201 is the cover's offset from that first image.
Future<Uint8List?> extractMobiCoverBytes(String bookPath) async {
  try {
    final bytes = await File(bookPath).readAsBytes();
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 78) return null;
    final numRecords = data.getUint16(76);
    if (bytes.length < 78 + numRecords * 8) return null;
    final offsets = [for (var i = 0; i < numRecords; i++) data.getUint32(78 + i * 8)];
    Uint8List? record(int i) {
      if (i < 0 || i >= numRecords) return null;
      final end = i + 1 < numRecords ? offsets[i + 1] : bytes.length;
      if (offsets[i] >= end || end > bytes.length) return null;
      return Uint8List.sublistView(bytes, offsets[i], end);
    }

    final r0 = offsets[0];
    if (String.fromCharCodes(bytes, r0 + 16, r0 + 20) != 'MOBI') return null;
    final mobiHeaderLen = data.getUint32(r0 + 20);
    final firstImage = data.getUint32(r0 + 108);
    final hasExth = (data.getUint32(r0 + 128) & 0x40) != 0;

    int? coverOffset;
    int? thumbOffset;
    final exth = r0 + 16 + mobiHeaderLen;
    if (hasExth && String.fromCharCodes(bytes, exth, exth + 4) == 'EXTH') {
      final count = data.getUint32(exth + 8);
      var pos = exth + 12;
      for (var i = 0; i < count && pos + 8 <= bytes.length; i++) {
        final type = data.getUint32(pos);
        final len = data.getUint32(pos + 4);
        if (len < 8) break;
        if (len >= 12) {
          if (type == 201) coverOffset = data.getUint32(pos + 8);
          if (type == 202) thumbOffset = data.getUint32(pos + 8);
        }
        pos += len;
      }
    }

    // 0xFFFFFFFF means "no cover".
    for (final off in [coverOffset, thumbOffset, 0]) {
      if (off == null || off == 0xFFFFFFFF) continue;
      final rec = record(firstImage + off);
      if (rec != null && _isImage(rec)) return Uint8List.fromList(rec);
    }
    return null;
  } catch (_) {
    return null;
  }
}

bool _isImage(Uint8List b) =>
    b.length > 4 &&
    ((b[0] == 0xFF && b[1] == 0xD8) || // JPEG
        (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) || // PNG
        (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) || // GIF
        (b[0] == 0x42 && b[1] == 0x4D)); // BMP

// Fallback for anything the built-in extractors can't handle, if Calibre is installed.
Future<Uint8List?> extractCalibreCoverBytes(String bookPath) async {
  const calibre = r'C:\Program Files\Calibre2\ebook-meta.exe';
  if (!await File(calibre).exists()) return null;
  final tmp = p.join(Directory.systemTemp.path, 'libri_cover_${DateTime.now().millisecondsSinceEpoch}.jpg');
  try {
    final result = await Process.run(calibre, ['--get-cover=$tmp', bookPath]);
    if (result.exitCode != 0) return null;
    final f = File(tmp);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    await f.delete();
    return bytes;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> extractCoverBytes(String bookPath) async {
  final ext = p.extension(bookPath).toLowerCase();
  Uint8List? coverBytes;
  if (ext == '.epub') {
    coverBytes = await extractEpubCoverBytes(bookPath);
  } else if (ext == '.pdf') {
    coverBytes = await extractPdfCoverBytes(bookPath);
  } else if (ext == '.mobi' || ext == '.azw' || ext == '.azw3') {
    coverBytes = await extractMobiCoverBytes(bookPath);
  }
  return coverBytes ?? await extractCalibreCoverBytes(bookPath);
}

// Loads the cached cover, extracting and caching it first if it's missing.
Future<Uint8List?> loadOrExtractCover(String bookPath) async {
  final cached = await loadCachedCover(bookPath);
  if (cached != null) return cached;
  final bytes = await extractCoverBytes(bookPath);
  if (bytes != null) {
    await File(p.join(p.dirname(bookPath), 'cover.jpg')).writeAsBytes(bytes);
  }
  return bytes;
}

// Windows' MAX_PATH. The name is used for both the book's folder and its file,
// so it gets half of whatever is left after the books dir and extension.
const _maxPath = 259;

String bookNameFor(String sourcePath, Directory booksDirPath) {
  final name = p.basenameWithoutExtension(sourcePath).trim();
  final ext = p.extension(sourcePath);
  final budget = (_maxPath - booksDirPath.path.length - 2 - ext.length) ~/ 2;
  final maxLen = budget.clamp(20, 120);
  if (name.length <= maxLen) return name;
  // Trim trailing separators/spaces left over from "Title -- Author -- ..." names.
  return name.substring(0, maxLen).replaceFirst(RegExp(r'[\s\-_.,;]+$'), '');
}

Future<({String bookPath, Uint8List? coverBytes})> importBook(String sourcePath, Directory booksDirPath) async {
  final name = bookNameFor(sourcePath, booksDirPath);
  final ext = p.extension(sourcePath);
  final bookDir = Directory(p.join(booksDirPath.path, name));
  final createdDir = !await bookDir.exists();
  if (createdDir) await bookDir.create();
  final bookPath = p.join(bookDir.path, '$name$ext');
  try {
    await File(sourcePath).copy(bookPath);
  } catch (_) {
    // Don't leave an empty folder behind if the copy fails.
    if (createdDir) await bookDir.delete(recursive: true).catchError((_) => bookDir);
    rethrow;
  }

  final coverBytes = await loadOrExtractCover(bookPath);
  return (bookPath: bookPath, coverBytes: coverBytes);
}
