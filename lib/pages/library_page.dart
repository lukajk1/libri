import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../models/book_entry.dart';
import '../services/library.dart';
import '../services/progress.dart';
import '../widgets/section.dart';
import '../widgets/status_label.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> with WindowListener {
  final List<BookEntry> _books = [];
  final ValueNotifier<String?> _selectedPath = ValueNotifier(null);
  String? _libraryPath;
  bool _loading = true;
  bool _refreshingProgress = false;
  bool _converting = false;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    HardwareKeyboard.instance.addHandler(_handleKey);
    _init();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // Ctrl+F focuses search, Esc clears it. Ignored while a dialog or menu is up.
  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || ModalRoute.of(context)?.isCurrent != true) return false;
    if (event.logicalKey == LogicalKeyboardKey.keyF && HardwareKeyboard.instance.isControlPressed) {
      _searchFocus.requestFocus();
      _searchController.selection = TextSelection(baseOffset: 0, extentOffset: _searchController.text.length);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && (_searchFocus.hasFocus || _query.isNotEmpty)) {
      _clearSearch();
      return true;
    }
    return false;
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    setState(() => _query = '');
  }

  /// Words of the search query; a book matches when its title contains all of them.
  List<String> get _searchWords =>
      _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  // Coming back to libri usually means a reader was just closed.
  @override
  void onWindowFocus() => _refreshProgress();

  Future<void> _refreshProgress() async {
    if (_refreshingProgress || _books.isEmpty) return;
    _refreshingProgress = true;
    try {
      final progress = await readProgress(_books.map((b) => b.storedPath).toList());
      if (!mounted) return;
      setState(() {
        for (final b in _books) {
          b.progress = progress[b.storedPath];
        }
      });
    } finally {
      _refreshingProgress = false;
    }
  }

  /// Converts any MOBI/AZW/AZW3 books to EPUB (via Calibre) and points the
  /// library at the EPUB. The original file stays in the book's folder.
  Future<void> _convertKindleBooks() async {
    if (_converting) return;
    final pending = _books.where((b) => isKindleFormat(b.storedPath)).toList();
    if (pending.isEmpty) return;
    _converting = true;
    try {
      var converted = 0;
      for (final book in pending) {
        _showMessage('Converting ${book.fileName} to EPUB...');
        final epub = await convertToEpub(book.storedPath);
        if (epub == null) continue;
        converted++;
        if (!mounted) return;
        setState(() => book.storedPath = epub);
        await _persist();
      }
      if (converted < pending.length) {
        _showMessage('Could not convert ${pending.length - converted} book(s) to EPUB. Is Calibre installed?');
      } else {
        _showMessage('Converted $converted book(s) to EPUB');
      }
      await _refreshProgress();
    } finally {
      _converting = false;
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
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
      final cover = await loadOrExtractCover(path);
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
    await _refreshProgress();
    await _convertKindleBooks();
  }

  Future<void> _persist() async {
    if (_libraryPath != null) await writeLibraryJson(_libraryPath!, _books);
  }

  Future<void> _addFiles(List<String> paths) async {
    if (_libraryPath == null) return;
    final dir = await booksDir(_libraryPath!);
    for (final path in paths) {
      final ext = p.extension(path).toLowerCase();
      if (ext != '.epub' && ext != '.mobi' && ext != '.azw' && ext != '.azw3' && ext != '.pdf') continue;
      final name = bookNameFor(path, dir);
      if (_books.any((b) => b.fileName == name)) continue;
      final ({String bookPath, Uint8List? coverBytes}) result;
      try {
        result = await importBook(path, dir);
      } catch (e) {
        _showMessage('Could not import ${p.basename(path)}: $e');
        continue;
      }
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
    await _convertKindleBooks();
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
      // The original MOBI/AZW/AZW3 is kept next to a converted EPUB.
      final stem = p.basenameWithoutExtension(book.storedPath);
      bool isExpected(String f) =>
          f == p.basename(book.storedPath) ||
          f == 'cover.jpg' ||
          (p.basenameWithoutExtension(f) == stem && isKindleFormat(f));
      final unexpected = contents.where((f) => !isExpected(f)).toList();
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
          actions: [
            _searchField(),
            const SizedBox(width: 8),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _libraryPath == null
                ? _noLibraryState()
                : _books.isEmpty
                    ? _emptyState()
                    : _searchWords.isNotEmpty
                        ? _searchResults()
                        : _sections(),
      ),
    );
  }

  Widget _searchField() {
    return Center(
      child: SizedBox(
        width: 200,
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          onChanged: (v) => setState(() => _query = v),
          style: const TextStyle(fontSize: 12),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Search titles',
            hintStyle: const TextStyle(fontSize: 12, color: Colors.white30),
            prefixIcon: const Icon(Icons.search, size: 14, color: Colors.white38),
            prefixIconConstraints: const BoxConstraints(minWidth: 28),
            suffixIcon: _query.isEmpty
                ? null
                : MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _clearSearch,
                      child: const Icon(Icons.close, size: 14, color: Colors.white38),
                    ),
                  ),
            suffixIconConstraints: const BoxConstraints(minWidth: 28),
            contentPadding: const EdgeInsets.symmetric(vertical: 5),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.06),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(4),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  Widget _searchResults() {
    final words = _searchWords;
    final matches = _books.where((b) {
      final title = b.fileName.toLowerCase();
      return words.every(title.contains);
    }).toList()
      ..sort((a, b) => b.importedAt.compareTo(a.importedAt));

    if (matches.isEmpty) {
      return Center(
        child: Text('No titles match "${_query.trim()}"',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 15)),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        LibrarySection(title: 'Results', books: matches, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook, alwaysExpanded: true),
      ],
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
        LibrarySection(title: 'Reading', color: BookStatus.reading.color, books: reading, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook, alwaysExpanded: true),
        LibrarySection(title: 'To Read', color: BookStatus.toRead.color, books: toRead, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook),
        LibrarySection(title: 'Completed', color: BookStatus.completed.color, books: completed, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook),
        LibrarySection(title: 'Dropped', color: BookStatus.dropped.color, books: dropped, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook),
        LibrarySection(title: 'All', books: all, selectedPath: _selectedPath, onSetStatus: _setStatus, onRemove: _removeBook, alwaysExpanded: true),
      ],
    );
  }
}
