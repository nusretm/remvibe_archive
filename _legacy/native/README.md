# RemVibe Archive native reader

This C++17 static library is the reusable native NTA V2 reader for RemVibe
applications. It does not install software, choose releases, or implement
Updater transactions.

```cmake
add_subdirectory(path/to/remvibe_archive/native remvibe_archive_native)
target_link_libraries(MyApplication PRIVATE remvibe::archive_native)
```

```cpp
auto archive = remvibe::archive::nta_v2_reader::open(package_path);
archive.extract_to(staging_path);
```

The current profile accepts only unencrypted NTA V2 and extracts regular files
and directories. Both stored and zlib-compressed entries are streamed and
verified against manifest size/SHA-256 before the staging tree is renamed to
the requested absent destination. Unsafe/aliased paths, gaps/overlaps,
symbolic links, unsupported critical metadata, and configured size-limit
violations fail before publication.

Build dependencies are pinned source revisions of official zlib (zlib license)
and nlohmann/json (MIT license). They are build-time inputs; the static library
does not add a separately installed application runtime.
