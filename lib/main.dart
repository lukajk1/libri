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

enum BookStatus { none, toRead, reading }

class BookEntry {
  final String fileName;
  final String storedPath;
  final Uint8List? coverBytes;
  BookStatus status;

  BookEntry({
    required this.fileName,
    required this.storedPath,
    this.coverBytes,
    this.status = BookStatus.none,
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

    final container = archive.findFile('META-INF/container.xml');
    if (container == null) return null;
    final containerXml = XmlDocument.parse(utf8.decode(container.content as List<int>));
    final opfPath = containerXml
        .findAllElements('rootfile')
        .first
        .getAttribute('full-path');
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPersistedBooks();
  }

  Future<void> _loadPersistedBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList('book_paths') ?? [];
    final statuses = prefs.getStringList('book_statuses') ?? [];
    final books = <BookEntry>[];
    for (int i = 0; i < stored.length; i++) {
      final path = stored[i];
      if (!await File(path).exists()) continue;
      final cover = await _extractEpubCover(path);
      final status = i < statuses.length
          ? BookStatus.values.firstWhere((s) => s.name == statuses[i], orElse: () => BookStatus.none)
          : BookStatus.none;
      books.add(BookEntry(fileName: p.basenameWithoutExtension(path), storedPath: path, coverBytes: cover, status: status));
    }
    if (mounted) setState(() { _books.addAll(books); _loading = false; });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('book_paths', _books.map((b) => b.storedPath).toList());
    await prefs.setStringList('book_statuses', _books.map((b) => b.status.name).toList());
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
        _books.add(BookEntry(fileName: p.basenameWithoutExtension(path), storedPath: dest, coverBytes: cover));
      });
    }
    await _persist();
  }

  void _setStatus(BookEntry book, BookStatus status) {
    setState(() => book.status = status);
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() {}),
      onDragExited: (_) => setState(() {}),
      onDragDone: (detail) => _addFiles(detail.files.map((f) => f.path).toList()),
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
                : _sections(),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined, size: 64, color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 16),
          Text('Drop epub or mobi files here',
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 15)),
        ],
      ),
    );
  }

  Widget _sections() {
    final reading = _books.where((b) => b.status == BookStatus.reading).toList();
    final toRead = _books.where((b) => b.status == BookStatus.toRead).toList();

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (reading.isNotEmpty)
          _Section(title: 'Reading', books: reading, onSetStatus: _setStatus),
        if (toRead.isNotEmpty)
          _Section(title: 'To Read', books: toRead, onSetStatus: _setStatus),
        _Section(title: 'All', books: _books, onSetStatus: _setStatus),
      ],
    );
  }
}

class _Section extends StatefulWidget {
  const _Section({required this.title, required this.books, required this.onSetStatus});
  final String title;
  final List<BookEntry> books;
  final void Function(BookEntry, BookStatus) onSetStatus;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(_expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 18, color: Colors.white38),
                const SizedBox(width: 6),
                Text(widget.title,
                    style: const TextStyle(fontSize: 13, color: Colors.white54, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Text('${widget.books.length}',
                    style: const TextStyle(fontSize: 12, color: Colors.white24)),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _BookGrid(books: widget.books, onSetStatus: widget.onSetStatus),
          ),
      ],
    );
  }
}

class _BookGrid extends StatelessWidget {
  const _BookGrid({required this.books, required this.onSetStatus});
  final List<BookEntry> books;
  final void Function(BookEntry, BookStatus) onSetStatus;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const tileWidth = 120.0;
        final cols = (constraints.maxWidth / (tileWidth + 12)).floor().clamp(1, 99);
        final tileHeight = tileWidth / 0.65;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final book in books)
              SizedBox(
                width: tileWidth,
                height: tileHeight,
                child: _BookTile(book: book, onSetStatus: onSetStatus),
              ),
          ],
        );
      },
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book, required this.onSetStatus});
  final BookEntry book;
  final void Function(BookEntry, BookStatus) onSetStatus;

  void _open() => Process.run('cmd', ['/c', 'start', '', book.storedPath]);

  void _showContextMenu(BuildContext context, Offset position) {
    showMenu<Object>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        const PopupMenuItem(value: 'open', child: Text('Open')),
        const PopupMenuItem(value: 'show', child: Text('Show in Explorer')),
        const PopupMenuDivider(),
        if (book.status != BookStatus.reading)
          const PopupMenuItem(value: BookStatus.reading, child: Text('Mark as Reading')),
        if (book.status != BookStatus.toRead)
          const PopupMenuItem(value: BookStatus.toRead, child: Text('Mark as To Read')),
        if (book.status != BookStatus.none)
          const PopupMenuItem(value: BookStatus.none, child: Text('Remove Status')),
      ],
    ).then((value) {
      if (value == 'open') _open();
      else if (value == 'show') Process.run('explorer.exe', ['/select,', book.storedPath]);
      else if (value is BookStatus) onSetStatus(book, value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: _open,
      onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
      child: Column(
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
      ),
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
