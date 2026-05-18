import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    return const MaterialApp(
      title: 'libri',
      debugShowCheckedModeBanner: false,
      home: Scaffold(),
    );
  }
}
