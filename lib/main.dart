import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(400, 500));
  await windowManager.setSize(const Size(520, 800));
  await windowManager.setTitle('libri');
  runApp(const LibriApp());
}

class BookEntry {
  final String fileName;
  final String storedPath;
  final Uint8List? coverBytes;

  const BookEntry({
    required this.fileName,
    required this.storedPath,
    this.coverBytes,
  });
}

Future<Directory> _booksDir() async {
  final appData = await getApplicationSupportDirectory();
  final dir = Directory(p.join(appData.path, 'books'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

Future<Uint8List?> _extractEpubCover(String path) async {
  try {
    final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());

    // Find the OPF file path from META-INF/container.xml
    final container = archive.findFile('META-INF/container.xml');
    if (container == null) return null;
    final containerXml = XmlDocument.parse(utf8.decode(container.content as List<int>));
    final opfPath = containerXml
        .findAllElements('rootfile')
        .first
        .getAttribute('full-path');
    if (opfPath == null) return null;

    // Parse the OPF to find the cover image href
    final opfFile = archive.findFile(opfPath);
    if (opfFile == null) return null;
    final opfXml = XmlDocument.parse(utf8.decode(opfFile.content as List<int>));
    final opfDir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';

    // Look for <meta name="cover" content="..."/> then resolve via manifest
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

    // Fallback: find any manifest item with 'cover' in the id or href
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
    final fullPath = '$opfDir$coverHref';
    final imageFile = archive.findFile(fullPath);
    if (imageFile == null) return null;
    return Uint8List.fromList(imageFile.content as List<int>);
  } catch (_) {
    return null;
  }
}


class LibriApp extends StatelessWidget {
  const LibriApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'libri',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1C1C1E),
      ),
      home: const LibraryPage(),
    );
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final List<BookEntry> _books = [];
  bool _dragging = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPersistedBooks();
  }

  Future<void> _loadPersistedBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('book_paths') ?? [];
    final books = <BookEntry>[];
    for (final path in stored) {
      if (!await File(path).exists()) continue;
      final cover = await _extractEpubCover(path);
      books.add(BookEntry(
        fileName: p.basenameWithoutExtension(path),
        storedPath: path,
        coverBytes: cover,
      ));
    }
    if (mounted) setState(() { _books.addAll(books); _loading = false; });
  }

  Future<void> _persistBooks() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('book_paths', _books.map((b) => b.storedPath).toList());
  }

  Future<void> _addFiles(List<String> paths) async {
    final dir = await _booksDir();
    for (final path in paths) {
      final ext = p.extension(path).toLowerCase();
      if (ext != '.epub' && ext != '.mobi') continue;
      final dest = p.join(dir.path, p.basename(path));
      if (_books.any((b) => b.storedPath == dest)) continue;
      await File(path).copy(dest);
      final cover = await _extractEpubCover(dest);
      setState(() {
        _books.add(BookEntry(
          fileName: p.basenameWithoutExtension(path),
          storedPath: dest,
          coverBytes: cover,
        ));
      });
    }
    await _persistBooks();
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        _addFiles(detail.files.map((f) => f.path).toList());
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 32,
          titleSpacing: 0,
          title: MenuBar(
            style: const MenuStyle(
              backgroundColor: WidgetStatePropertyAll(Colors.transparent),
              elevation: WidgetStatePropertyAll(0),
              padding: WidgetStatePropertyAll(EdgeInsets.zero),
            ),
            children: [
              SubmenuButton(
                menuChildren: [
                  MenuItemButton(
                    child: const Text('Open Library Folder'),
                    onPressed: () async {
                      final dir = await _booksDir();
                      await Process.run('explorer.exe', [dir.path]);
                    },
                  ),
                ],
                child: const Text('File'),
              ),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _books.isEmpty
                ? _emptyState()
                : _grid(),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined,
              size: 64, color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 16),
          Text(
            'Drop epub or mobi files here',
            style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _grid() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.65,
      ),
      itemCount: _books.length,
      itemBuilder: (context, i) => _BookTile(book: _books[i]),
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book});
  final BookEntry book;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: book.coverBytes != null
                ? Image.memory(book.coverBytes!, fit: BoxFit.cover)
                : _placeholder(),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          book.fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFF2C2C2E),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            book.fileName,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Colors.white30),
          ),
        ),
      ),
    );
  }
}
