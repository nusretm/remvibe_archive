import 'package:flutter/material.dart';

import 'screens/main_screen.dart';

void main() {
  runApp(const ExapmleApp());
}

class ExapmleApp extends StatelessWidget {
  const ExapmleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remvibe Archiver',
      theme: MediaQuery.of(context).platformBrightness == Brightness.dark ? ThemeData.dark(): ThemeData.light(),
      home: const MainScreen(),
    );
  }
}
