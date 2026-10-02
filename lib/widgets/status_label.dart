import 'package:flutter/material.dart';

import '../models/book_entry.dart';

extension BookStatusStyle on BookStatus {
  String get label => switch (this) {
        BookStatus.none => '',
        BookStatus.toRead => 'To Read',
        BookStatus.reading => 'Reading',
        BookStatus.completed => 'Completed',
        BookStatus.dropped => 'Dropped',
      };

  Color? get color => switch (this) {
        BookStatus.none => null,
        BookStatus.toRead => const Color(0xFFFFD54F),
        BookStatus.reading => const Color(0xFF64B5F6),
        BookStatus.completed => const Color(0xFF81C784),
        BookStatus.dropped => const Color(0xFFE57373),
      };
}

/// The colored status tag drawn over a book's cover.
class StatusLabel extends StatelessWidget {
  const StatusLabel(this.status, {super.key});

  final BookStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: status.color,
        borderRadius: BorderRadius.circular(3),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
      ),
      child: Text(
        status.label.toUpperCase(),
        style: const TextStyle(
          fontSize: 9,
          height: 1.2,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Colors.black87,
        ),
      ),
    );
  }
}
