import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:window_manager/window_manager.dart';

import 'pages/library_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  await windowManager.ensureInitialized();
  await windowManager.setMinimumSize(const Size(400, 500));
  await windowManager.setSize(const Size(520, 800));
  await windowManager.setTitle('libri');
  runApp(const LibriApp());
}

class LibriApp extends StatelessWidget {
  const LibriApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'libri',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF383637),
      ),
      home: const LibraryPage(),
    );
  }
}
