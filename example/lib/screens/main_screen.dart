import 'dart:io';

import 'package:flutter/material.dart';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:remvibe_archive/remvibe_archive.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _dragging = false;
  RemvibeArchive archive = RemvibeArchive();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text('Remvibe Archiver'),
      ),
      body: DropTarget(
        enable: true,
        onDragDone: (detail) async {
          for (final file in detail.files) {
            String aName = file.name;
            String aPath = file.path.replaceFirst(aName, '');
            Directory dirTest = Directory(file.path);
            if (dirTest.existsSync()) {
              archive.addFolder(file.path);
              debugPrint(
                '>>>>> $aPath -> $aName (Folder)'
              );
            } else {
              archive.addFile(file.path);
              debugPrint(
                '> $aPath -> $aName'
                '  ${await file.lastModified()}'
                '  ${await file.length()}'
                '  ${file.mimeType}'
              );
            }
          }
          archive.debugPrint();
        },
        onDragUpdated: (detail) {
          //debugPrint("${detail.localPosition.dx}x${detail.localPosition.dy}");
          // setState(() {
            // offset = details.localPosition;
          // });
        },
        onDragEntered: (detail) {
          //debugPrint("${detail.localPosition.dx}x${detail.localPosition.dy}");
          setState(() {
            _dragging = true;
          });
        },
        onDragExited: (detail) {
          setState(() {
            _dragging = false;
          });
        },
        child: Stack(
          children: [
            Column(
              mainAxisAlignment: .center,
              children: [
                Center(child: const Text('You can drop files')),
              ],
            ),
            if(_dragging)
            Positioned(
              child: Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.onSurface.withAlpha(80),
                  ),
                  child: Center(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.all(Radius.circular(14)),
                        boxShadow: List.from([
                          BoxShadow(blurRadius: 4.0),
                        ]),
                        color: Theme.of(context).colorScheme.surface,
                      ),
                      height: 100,
                      width: 200,
                      child: Center(child: Text('Drop File or Folder', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontWeight: .bold), textAlign: .center))
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
        },
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}