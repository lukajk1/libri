import 'dart:io';

import 'package:flutter/material.dart';

import '../models/book_entry.dart';

void openBook(BuildContext context, String storedPath) {
  Process.run('cmd', ['/c', 'start', '', storedPath]);
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Opening — this may take a moment...'),
      duration: Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      width: 280,
    ),
  );
}

class BookTile extends StatefulWidget {
  const BookTile({
    super.key,
    required this.book,
    required this.selectedPath,
    required this.onSetStatus,
  });

  final BookEntry book;
  final ValueNotifier<String?> selectedPath;
  final void Function(BookEntry, BookStatus) onSetStatus;

  @override
  State<BookTile> createState() => _BookTileState();
}

class _BookTileState extends State<BookTile> {
  void _open() => openBook(context, widget.book.storedPath);

  void _showContextMenu(BuildContext context, Offset position) {
    showMenu<Object>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx, position.dy),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        const PopupMenuItem(value: 'open', child: Text('Open')),
        const PopupMenuDivider(),
        if (widget.book.status != BookStatus.reading)
          const PopupMenuItem(value: BookStatus.reading, child: Text('Mark as Reading')),
        if (widget.book.status != BookStatus.toRead)
          const PopupMenuItem(value: BookStatus.toRead, child: Text('Mark as To Read')),
        if (widget.book.status != BookStatus.completed)
          const PopupMenuItem(value: BookStatus.completed, child: Text('Mark as Completed')),
        if (widget.book.status != BookStatus.none)
          const PopupMenuItem(value: BookStatus.none, child: Text('Remove Status')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'show', child: Text('Show in Explorer')),
      ],
    ).then((value) {
      if (value == 'open') _open();
      else if (value == 'show') Process.run('explorer.exe', ['/select,"${widget.book.storedPath}"']);
      else if (value is BookStatus) widget.onSetStatus(widget.book, value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final path = widget.book.storedPath;
        widget.selectedPath.value = widget.selectedPath.value == path ? null : path;
      },
      onDoubleTap: _open,
      onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
      child: ValueListenableBuilder<String?>(
        valueListenable: widget.selectedPath,
        builder: (context, selected, _) {
          final isSelected = selected == widget.book.storedPath;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.book.coverBytes != null
                          ? Image.memory(widget.book.coverBytes!, fit: BoxFit.contain)
                          : _placeholder(),
                      if (isSelected)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 2),
                            borderRadius: BorderRadius.circular(4),
                            color: Colors.white.withOpacity(0.1),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.book.fileName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: isSelected ? Colors.white : Colors.white70),
              ),
            ],
          );
        },
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
            widget.book.fileName,
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
