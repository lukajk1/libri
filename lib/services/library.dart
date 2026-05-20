import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:pdf_render/pdf_render.dart';
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
  try {
    final doc = await PdfDocument.openFile(bookPath);
    final page = await doc.getPage(1);
    final image = await page.render(
      width: page.width.toInt(),
      height: page.height.toInt(),
    );
    final pngBytes = await image.createImageDetached().then((img) async {
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    });
    return pngBytes;
  } catch (_) {
    return null;
  }
}

Future<Uint8List?> loadCachedCover(String bookPath) async {
  final coverFile = File(p.join(p.dirname(bookPath), 'cover.jpg'));
  if (await coverFile.exists()) return coverFile.readAsBytes();
  return null;
}

Future<({String bookPath, Uint8List? coverBytes})> importBook(String sourcePath, Directory booksDirPath) async {
  final name = p.basenameWithoutExtension(sourcePath);
  final ext = p.extension(sourcePath);
  final bookDir = Directory(p.join(booksDirPath.path, name));
  if (!await bookDir.exists()) await bookDir.create();
  final bookPath = p.join(bookDir.path, p.basename(sourcePath));
  await File(sourcePath).copy(bookPath);

  Uint8List? coverBytes;
  if (ext.toLowerCase() == '.epub') {
    coverBytes = await extractEpubCoverBytes(bookPath);
  } else if (ext.toLowerCase() == '.pdf') {
    coverBytes = await extractPdfCoverBytes(bookPath);
  }
  if (coverBytes != null) {
    await File(p.join(bookDir.path, 'cover.jpg')).writeAsBytes(coverBytes);
  }
  return (bookPath: bookPath, coverBytes: coverBytes);
}
