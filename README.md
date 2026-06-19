# Remvibe Archive

A Dart library for creating and managing encrypted archive files with AES encryption, compatible with Remvibe archive format.

## Features

- AES encryption for secure archiving
- Support for hierarchical folders and files
- CRC32 checksums for data integrity verification
- ZLib compression for efficient storage
- Compatible with existing Remvibe archive format (Delphi-based)

## Installation

Add `Remvibe_archive` to your `pubspec.yaml` dependencies:

```yaml
dependencies:
  Remvibe_archive: ^1.0.0
```

Then run:

```bash
dart pub get
```

## Usage

### Creating an Archive

```dart
import 'package:Remvibe_archive/Remvibe_archive.dart';

void main() {
  // Create a new archive with a passphrase
  var archive = RemvibeArchive('your_secret_passphrase', 'my_archive.nta');

  // Add files and folders to the root
  // (Implementation depends on ArchiveFolder and ArchiveFile classes)

  // Save the archive to file
  archive.updateFile();
}
```

### Loading an Archive

```dart
import 'package:Remvibe_archive/Remvibe_archive.dart';

void main() {
  // Load an existing archive
  var archive = RemvibeArchive('your_secret_passphrase', 'my_archive.nta');

  if (archive.loadFromFile()) {
    print('Archive loaded successfully');

    // Access files
    for (var file in archive.root.files) {
      print('File: ${file.fullName}');
      // Extract file if needed
      var error = file.extract('output_directory');
      if (error.isNotEmpty) {
        print('Extraction error: $error');
      }
    }
  } else {
    print('Failed to load archive');
  }
}
```

### Command Line Usage

The package includes a command-line tool in `bin/Remvibe_archive.dart` for basic operations:

```bash
dart run Remvibe_archive
```

## API Reference

### RemvibeArchive

- `RemvibeArchive(String cryptKey, String fileName)`: Constructor that initializes the archive with an encryption key and file path.
- `void updateFile()`: Encrypts and writes the archive structure and content to the specified file.
- `bool loadFromFile()`: Decrypts and loads the archive from the file, returning true on success.

### ArchiveFolder

Represents a folder in the archive hierarchy.

### ArchiveFile

Represents a file in the archive with methods for extraction.

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
