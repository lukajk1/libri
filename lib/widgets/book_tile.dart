import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/book_entry.dart';
import 'status_label.dart';

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
    required this.sectionKey,
    required this.onSetStatus,
    required this.onRemove,
  });

  final BookEntry book;
  final ValueNotifier<String?> selectedPath;
  final String sectionKey;
  final void Function(BookEntry, BookStatus) onSetStatus;
  final void Function(BookEntry) onRemove;

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
        for (final status in const [BookStatus.reading, BookStatus.toRead, BookStatus.completed, BookStatus.dropped])
          if (widget.book.status != status)
            PopupMenuItem(
              value: status,
              child: Text.rich(TextSpan(children: [
                const TextSpan(text: 'Mark as '),
                TextSpan(text: status.label, style: TextStyle(color: status.color)),
              ])),
            ),
        if (widget.book.status != BookStatus.none)
          const PopupMenuItem(value: BookStatus.none, child: Text('Remove Status')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'show', child: Text('Show in Explorer')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'remove', child: Text('Remove from Library')),
      ],
    ).then((value) {
      if (value == 'open') _open();
      else if (value == 'show') Process.run('explorer.exe', [p.dirname(widget.book.storedPath)]);
      else if (value == 'remove') widget.onRemove(widget.book);
      else if (value is BookStatus) widget.onSetStatus(widget.book, value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final key = '${widget.sectionKey}::${widget.book.storedPath}';
        widget.selectedPath.value = widget.selectedPath.value == key ? null : key;
      },
      onDoubleTap: _open,
      onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
      child: ValueListenableBuilder<String?>(
        valueListenable: widget.selectedPath,
        builder: (context, selected, _) {
          final isSelected = selected == '${widget.sectionKey}::${widget.book.storedPath}';
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
                          ? _Cover(bytes: widget.book.coverBytes!, label: _statusLabel())
                          : Stack(
                              fit: StackFit.expand,
                              children: [
                                _placeholder(),
                                if (_statusLabel() case final label?)
                                  Positioned(top: 4, left: 4, child: label),
                              ],
                            ),
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
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  _progressLabel(),
                  style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.white54),
                ),
              ),
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

  Widget? _statusLabel() =>
      widget.book.status == BookStatus.none ? null : StatusLabel(widget.book.status);

  String _progressLabel() {
    final progress = widget.book.progress;
    if (progress != null) return '${(progress * 100).round()}%';
    return widget.book.status == BookStatus.completed ? 'Finished' : '-';
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

/// A cover fitted inside its box, with [label] pinned to the top-left of the
/// image itself rather than of the (possibly letterboxed) box.
class _Cover extends StatefulWidget {
  const _Cover({required this.bytes, this.label});

  final Uint8List bytes;
  final Widget? label;

  @override
  State<_Cover> createState() => _CoverState();
}

class _CoverState extends State<_Cover> {
  ImageStream? _stream;
  double? _aspect;
  late final _listener = ImageStreamListener((info, _) {
    final aspect = info.image.width / info.image.height;
    info.dispose();
    if (mounted) setState(() => _aspect = aspect);
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_Cover old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) _resolve();
  }

  // Same provider as Image.memory below, so this shares its cache entry.
  void _resolve() {
    final stream = MemoryImage(widget.bytes).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = Image.memory(widget.bytes, fit: BoxFit.contain);
    final aspect = _aspect;
    if (aspect == null) return image;
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            if (widget.label case final label?) Positioned(top: 4, left: 4, child: label),
          ],
        ),
      ),
    );
  }
}
