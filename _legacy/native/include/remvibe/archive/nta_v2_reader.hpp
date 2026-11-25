#pragma once

#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <vector>

namespace remvibe::archive {

enum class entry_type {
  file,
  directory,
  symbolic_link,
};

enum class compression {
  none,
  zlib,
};

struct entry_info {
  std::string path;
  entry_type type;
  std::uint64_t size;
  std::string sha256;
  compression compression_method;
  std::uint64_t data_offset;
  std::uint64_t stored_size;
  std::vector<std::string> critical_metadata;
};

struct extraction_limits {
  std::uint64_t max_entries = 100000;
  std::uint64_t max_entry_uncompressed_bytes = 16ULL * 1024ULL * 1024ULL * 1024ULL;
  std::uint64_t max_total_uncompressed_bytes = 64ULL * 1024ULL * 1024ULL * 1024ULL;
  std::uint64_t max_stored_body_bytes = 64ULL * 1024ULL * 1024ULL * 1024ULL;
  std::uint64_t max_manifest_bytes = 16ULL * 1024ULL * 1024ULL;
};

class archive_error final : public std::runtime_error {
 public:
  explicit archive_error(const std::string& message) : std::runtime_error(message) {}
};

class nta_v2_reader final {
 public:
  static nta_v2_reader open(
      const std::filesystem::path& archive_path,
      extraction_limits limits = {});

  const std::filesystem::path& archive_path() const noexcept { return archive_path_; }
  const std::vector<entry_info>& entries() const noexcept { return entries_; }

  void extract_to(const std::filesystem::path& destination) const;

 private:
  std::filesystem::path archive_path_;
  extraction_limits limits_;
  std::uint64_t body_offset_ = 0;
  std::uint64_t payload_offset_ = 0;
  std::vector<entry_info> entries_;
};

std::string sha256_file_hex(const std::filesystem::path& path);

}  // namespace remvibe::archive
