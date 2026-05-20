import 'dart:typed_data';

enum BookStatus { none, toRead, reading, completed }

class BookEntry {
  final String fileName;
  final String storedPath;
  final Uint8List? coverBytes;
  final int importedAt;
  BookStatus status;

  BookEntry({
    required this.fileName,
    required this.storedPath,
    required this.importedAt,
    this.coverBytes,
    this.status = BookStatus.none,
  });
}
