import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/book_entry.dart';
import '../services/library.dart';
import '../widgets/section.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final List<BookEntry> _books = [];
  final ValueNotifier<String?> _selectedPath = ValueNotifier(null);
  String? _libraryPath;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final path = await loadLibraryPath();
    final valid = path != null && await Directory(path).exists();
    if (!valid) {
      await _pickLibraryPath(initial: true);
    } else {
      _libraryPath = path;
      await _loadBooks();
    }
  }

  Future<void> _pickLibraryPath({bool initial = false}) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: initial ? 'Choose a folder for your library' : 'Change library location',
    );
    if (result == null) {
      if (initial && mounted) setState(() => _loading = false);
      return;
    }
    await saveLibraryPath(result);
    _libraryPath = result;
    if (initial) {
      await _loadBooks();
    } else {
      setState(() { _books.clear(); _loading = true; });
      await _loadBooks();
    }
  }

  Future<void> _loadBooks() async {
    final libraryPath = _libraryPath;
    if (libraryPath == null) return;

    final entries = await readLibraryJson(libraryPath);
    final books = <BookEntry>[];
    for (final entry in entries) {
      final path = entry['path'] as String;
      if (!await File(path).exists()) continue;
      final cover = await loadCachedCover(path);
      final status = BookStatus.values.firstWhere(
        (s) => s.name == entry['status'],
        orElse: () => BookStatus.none,
      );
      final importedAt = (entry['importedAt'] as num?)?.toInt() ?? 0;
      final statusChangedAt = (entry['statusChangedAt'] as num?)?.toInt();
      books.add(BookEntry(
        fileName: p.basenameWithoutExtension(path),
        storedPath: path,
        coverBytes: cover,
        status: status,
        importedAt: importedAt,
        statusChangedAt: statusChangedAt,
      ));
    }
    if (mounted) setState(() { _books.addAll(books); _loading = false; });
  }

  Future<void> _persist() async {
    if (_libraryPath != null) await writeLibraryJson(_libraryPath!, _books);
  }

  Future<void> _addFiles(List<String> paths) async {
    if (_libraryPath == null) return;
    final dir = await booksDir(_libraryPath!);
    for (final path in paths) {
      final ext = p.extension(path).toLowerCase();
      if (ext != '.epub' && ext != '.mobi' && ext != '.pdf') continue;
      final name = p.basenameWithoutExtension(path);
      if (_books.any((b) => b.fileName == name)) continue;
      final result = await importBook(path, dir);
      setState(() {
        _books.add(BookEntry(
          fileName: name,
          storedPath: result.bookPath,
          coverBytes: result.coverBytes,
          importedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ));
      });
    }
    await _persist();
  }

  void _setStatus(BookEntry book, BookStatus status) {
    setState(() {
      book.status = status;
      book.statusChangedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    });
    _persist();
  }

  Future<void> _removeBook(BookEntry book) async {
    final bookDir = Directory(p.dirname(book.storedPath));
    if (await bookDir.exists()) {
      final contents = await bookDir.list().map((e) => p.basename(e.path)).toList();
      const expected = {'cover.jpg'};
      final unexpected = contents.where((f) => f != p.basename(book.storedPath) && !expected.contains(f)).toList();
      if (unexpected.isNotEmpty) {
        if (!mounted) return;
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Unexpected files'),
            content: Text(
              'The folder contains unexpected files:\n${unexpected.join(', ')}\n\nDelete anyway?',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        );
        if (confirm != true) return;
      }
      await bookDir.delete(recursive: true);
    }
    setState(() => _books.remove(book));
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) {},
      onDragExited: (_) {},
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
                    onPressed: () {
                      if (_libraryPath != null) Process.run('explorer.exe', [_libraryPath!]);
                    },
                  ),
                  MenuItemButton(
                    child: const Text('Change Library Location'),
                    onPressed: () => _pickLibraryPath(),
                  ),
                ],
                child: const Text('File'),
              ),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _libraryPath == null
                ? _noLibraryState()
                : _books.isEmpty
                    ? _emptyState()
                    : _sections(),
      ),
    );
  }

  Widget _noLibraryState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_open, size: 64, color: Colors.white.withOpacity(0.15)),
          const SizedBox(height: 16),
          Text('No library selected',
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 15)),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => _pickLibraryPath(initial: true),
            child: const Text('Choose folder'),
          ),
        ],
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
          Text('Drop epub, mobi, or pdf files here',
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 15)),
        ],
      ),
    );
  }

  Widget _sections() {
    int byStatusChanged(BookEntry a, BookEntry b) => b.statusChangedAt.compareTo(a.statusChangedAt);
    int byImported(BookEntry a, BookEntry b) => b.importedAt.compareTo(a.importedAt);

    final reading = _books.where((b) => b.status == BookStatus.reading).toList()..sort(byStatusChanged);
    final toRead = _books.where((b) => b.status == BookStatus.toRead).toList()..sort(byStatusChanged);
    final completed = _books.where((b) => b.status == BookStatus.completed).toList()..sort(byStatusChanged);
    final dropped = _books.where((b) => b.status == BookStatus.dropped).toList()..sort(byStatusChanged);
    final all = [..._books]..sort(byImported);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        LibrarySection(title: 'Reading', books: reading, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook, alwaysExpanded: true),
        LibrarySection(title: 'To Read', books: toRead, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook),
        LibrarySection(title: 'Completed', books: completed, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook),
        LibrarySection(title: 'Dropped', books: dropped, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook),
        LibrarySection(title: 'All', books: all, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook, alwaysExpanded: true),
      ],
    );
  }
}
