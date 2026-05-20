import 'package:flutter/material.dart';

import '../models/book_entry.dart';
import 'book_grid.dart';

class LibrarySection extends StatefulWidget {
  const LibrarySection({
    super.key,
    required this.title,
    required this.books,
    required this.selectedPath,
    required this.onSetStatus,
    required this.onRemove,
  });

  final String title;
  final List<BookEntry> books;
  final ValueNotifier<String?> selectedPath;
  final void Function(BookEntry, BookStatus) onSetStatus;
  final void Function(BookEntry) onRemove;

  @override
  State<LibrarySection> createState() => _LibrarySectionState();
}

class _LibrarySectionState extends State<LibrarySection> {
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
            child: BookGrid(
              books: widget.books,
              selectedPath: widget.selectedPath,
              sectionKey: widget.title,
              onSetStatus: widget.onSetStatus,
              onRemove: widget.onRemove,
            ),
          ),
      ],
    );
  }
}
