import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final target = input.config.code;
    final (rustTarget, libraryName) = switch (
        (target.targetOS, target.targetArchitecture)) {
      (OS.windows, Architecture.x64) =>
        ('x86_64-pc-windows-msvc', 'remvibe_archive_ffi.dll'),
      (OS.linux, Architecture.x64) =>
        ('x86_64-unknown-linux-gnu', 'libremvibe_archive_ffi.so'),
      (OS.linux, Architecture.arm64) =>
        ('aarch64-unknown-linux-gnu', 'libremvibe_archive_ffi.so'),
      (OS.macOS, Architecture.x64) =>
        ('x86_64-apple-darwin', 'libremvibe_archive_ffi.dylib'),
      (OS.macOS, Architecture.arm64) =>
        ('aarch64-apple-darwin', 'libremvibe_archive_ffi.dylib'),
      _ => throw UnsupportedError(
          'Unsupported Archive target: ${target.targetOS.name}/'
          '${target.targetArchitecture.name}'),
    };
    final root = input.packageRoot.resolve('../');
    final native = input.packageRoot.resolve('native/');
    final manifest = native.resolve('Cargo.toml');
    if (!File.fromUri(manifest).existsSync() ||
        !File.fromUri(root.resolve('Cargo.toml')).existsSync()) {
      throw StateError('Archive Rust manifests missing: ${manifest.toFilePath()}');
    }
    final buildDirectory = input.outputDirectoryShared.resolve('cargo-target/');
    final result = await Process.run('cargo', [
      'build', '--locked', '--release',
      '--manifest-path', manifest.toFilePath(),
      '--target', rustTarget,
      '--target-dir', buildDirectory.toFilePath(),
    ], workingDirectory: native.toFilePath());
    if (result.exitCode != 0) {
      throw StateError('Cargo failed for $rustTarget: ${result.stdout}\n${result.stderr}');
    }
    final library = buildDirectory.resolve('$rustTarget/release/$libraryName');
    if (!File.fromUri(library).existsSync()) {
      throw StateError('Cargo output missing: ${library.toFilePath()}');
    }
    for (final directory in [root, native]) {
      output.dependencies.add(directory.resolve('Cargo.toml'));
      output.dependencies.add(directory.resolve('Cargo.lock'));
      for (final entry in Directory.fromUri(directory.resolve('src/'))
          .listSync(recursive: true)) {
        if (entry is File && entry.path.endsWith('.rs')) {
          output.dependencies.add(entry.uri);
        }
      }
    }
    output.dependencies.add(native.resolve('include/remvibe_archive.h'));
    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: 'src/native/bindings.dart',
      linkMode: DynamicLoadingBundled(),
      file: library,
    ));
  });
}
