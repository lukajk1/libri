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
    this.alwaysExpanded = false,
    this.color,
  });

  final String title;
  /// Status color for the title; plain if null.
  final Color? color;
  final List<BookEntry> books;
  final ValueNotifier<String?> selectedPath;
  final void Function(BookEntry, BookStatus) onSetStatus;
  final void Function(BookEntry) onRemove;
  final bool alwaysExpanded;

  @override
  State<LibrarySection> createState() => _LibrarySectionState();
}

class _LibrarySectionState extends State<LibrarySection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final grid = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: BookGrid(
        books: widget.books,
        selectedPath: widget.selectedPath,
        sectionKey: widget.title,
        onSetStatus: widget.onSetStatus,
        onRemove: widget.onRemove,
      ),
    );

    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (!widget.alwaysExpanded) ...[
            Icon(_expanded ? Icons.expand_more : Icons.chevron_right,
                size: 18, color: Colors.white38),
            const SizedBox(width: 6),
          ],
          Text(widget.title,
              style: TextStyle(fontSize: 13, color: widget.color ?? Colors.white54, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('${widget.books.length}',
              style: const TextStyle(fontSize: 12, color: Colors.white24)),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.alwaysExpanded)
          header
        else
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: header,
          ),
        if (widget.alwaysExpanded || _expanded)
          grid,
        const SizedBox(height: 8),
      ],
    );
  }
}
