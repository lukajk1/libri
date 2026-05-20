import 'package:flutter/material.dart';

import '../models/book_entry.dart';
import 'book_tile.dart';

class BookGrid extends StatelessWidget {
  const BookGrid({
    super.key,
    required this.books,
    required this.selectedPath,
    required this.onSetStatus,
  });

  final List<BookEntry> books;
  final ValueNotifier<String?> selectedPath;
  final void Function(BookEntry, BookStatus) onSetStatus;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const tileWidth = 120.0;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final book in books)
              SizedBox(
                width: tileWidth,
                child: BookTile(book: book, selectedPath: selectedPath, onSetStatus: onSetStatus),
              ),
          ],
        );
      },
    );
  }
}
