import 'dart:typed_data';

enum BookStatus { none, toRead, reading, completed, dropped }

class BookEntry {
  final String fileName;
  String storedPath;
  final Uint8List? coverBytes;
  final int importedAt;
  BookStatus status;
  int statusChangedAt;
  /// Reading progress (0..1) read back from the reader app, if known.
  double? progress;

  BookEntry({
    required this.fileName,
    required this.storedPath,
    required this.importedAt,
    this.coverBytes,
    this.status = BookStatus.none,
    int? statusChangedAt,
  }) : statusChangedAt = statusChangedAt ?? importedAt;
}
