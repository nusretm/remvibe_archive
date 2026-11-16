#include "remvibe/archive/nta_v2_reader.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <limits>
#include <random>
#include <set>
#include <sstream>
#include <unordered_map>

#include <nlohmann/json.hpp>
#include <zlib.h>

namespace remvibe::archive {

namespace {

namespace fs = std::filesystem;
using json = nlohmann::json;

constexpr std::array<unsigned char, 8> k_magic = {
    0x4e, 0x54, 0x41, 0x32, 0x0d, 0x0a, 0x1a, 0x0a};
constexpr std::uint64_t k_preamble_length = 24;
constexpr std::uint64_t k_max_public_header_length = 1024ULL * 1024ULL;
constexpr std::size_t k_io_chunk = 1024U * 1024U;

std::uint16_t be16(const unsigned char* value) {
  return static_cast<std::uint16_t>((value[0] << 8U) | value[1]);
}

std::uint32_t be32(const unsigned char* value) {
  return (static_cast<std::uint32_t>(value[0]) << 24U) |
         (static_cast<std::uint32_t>(value[1]) << 16U) |
         (static_cast<std::uint32_t>(value[2]) << 8U) |
         static_cast<std::uint32_t>(value[3]);
}

std::uint64_t be64(const unsigned char* value) {
  std::uint64_t result = 0;
  for (int index = 0; index < 8; ++index) {
    result = (result << 8U) | value[index];
  }
  return result;
}

void read_exact(std::istream& input, unsigned char* output, std::size_t size,
                const char* label) {
  if (size > static_cast<std::size_t>(std::numeric_limits<std::streamsize>::max())) {
    throw archive_error(std::string(label) + " is too large.");
  }
  input.read(reinterpret_cast<char*>(output), static_cast<std::streamsize>(size));
  if (input.gcount() != static_cast<std::streamsize>(size)) {
    throw archive_error(std::string("Truncated ") + label + ".");
  }
}

std::vector<unsigned char> read_bytes(std::istream& input, std::size_t size,
                                      const char* label) {
  std::vector<unsigned char> bytes(size);
  read_exact(input, bytes.data(), bytes.size(), label);
  return bytes;
}

class sha256 final {
 public:
  sha256() { reset(); }

  void update(const unsigned char* data, std::size_t length) {
    bit_length_ += static_cast<std::uint64_t>(length) * 8ULL;
    while (length > 0) {
      const auto count = std::min(length, block_.size() - block_length_);
      std::memcpy(block_.data() + block_length_, data, count);
      block_length_ += count;
      data += count;
      length -= count;
      if (block_length_ == block_.size()) {
        transform(block_.data());
        block_length_ = 0;
      }
    }
  }

  std::string finish_hex() {
    const auto original_bits = bit_length_;
    block_[block_length_++] = 0x80;
    if (block_length_ > 56) {
      std::fill(block_.begin() + static_cast<std::ptrdiff_t>(block_length_),
                block_.end(), static_cast<unsigned char>(0));
      transform(block_.data());
      block_length_ = 0;
    }
    std::fill(block_.begin() + static_cast<std::ptrdiff_t>(block_length_),
              block_.begin() + 56, static_cast<unsigned char>(0));
    for (int index = 0; index < 8; ++index) {
      block_[63 - index] = static_cast<unsigned char>(original_bits >> (index * 8));
    }
    transform(block_.data());

    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (const auto word : state_) {
      output << std::setw(8) << word;
    }
    return output.str();
  }

 private:
  static std::uint32_t rotate(std::uint32_t value, int bits) {
    return (value >> bits) | (value << (32 - bits));
  }

  void reset() {
    state_ = {0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
              0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U};
    block_.fill(0);
    block_length_ = 0;
    bit_length_ = 0;
  }

  void transform(const unsigned char* block) {
    static constexpr std::array<std::uint32_t, 64> constants = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU,
        0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U, 0xd807aa98U, 0x12835b01U,
        0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U,
        0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU,
        0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U,
        0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U,
        0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
        0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U,
        0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U, 0x1e376c08U,
        0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU,
        0x682e6ff3U, 0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U,
        0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U};
    std::array<std::uint32_t, 64> words{};
    for (int index = 0; index < 16; ++index) {
      words[index] = be32(block + index * 4);
    }
    for (int index = 16; index < 64; ++index) {
      const auto s0 = rotate(words[index - 15], 7) ^
                      rotate(words[index - 15], 18) ^ (words[index - 15] >> 3U);
      const auto s1 = rotate(words[index - 2], 17) ^
                      rotate(words[index - 2], 19) ^ (words[index - 2] >> 10U);
      words[index] = words[index - 16] + s0 + words[index - 7] + s1;
    }
    auto a = state_[0]; auto b = state_[1]; auto c = state_[2]; auto d = state_[3];
    auto e = state_[4]; auto f = state_[5]; auto g = state_[6]; auto h = state_[7];
    for (int index = 0; index < 64; ++index) {
      const auto s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25);
      const auto choose = (e & f) ^ (~e & g);
      const auto temporary1 = h + s1 + choose + constants[index] + words[index];
      const auto s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22);
      const auto majority = (a & b) ^ (a & c) ^ (b & c);
      const auto temporary2 = s0 + majority;
      h = g; g = f; f = e; e = d + temporary1;
      d = c; c = b; b = a; a = temporary1 + temporary2;
    }
    state_[0] += a; state_[1] += b; state_[2] += c; state_[3] += d;
    state_[4] += e; state_[5] += f; state_[6] += g; state_[7] += h;
  }

  std::array<std::uint32_t, 8> state_{};
  std::array<unsigned char, 64> block_{};
  std::size_t block_length_ = 0;
  std::uint64_t bit_length_ = 0;
};

std::uint64_t unsigned_integer(const json& value, const char* label) {
  if (value.is_number_unsigned()) {
    return value.get<std::uint64_t>();
  }
  if (value.is_number_integer()) {
    const auto signed_value = value.get<std::int64_t>();
    if (signed_value >= 0) return static_cast<std::uint64_t>(signed_value);
  }
  throw archive_error(std::string("Invalid non-negative integer field: ") + label);
}

std::string ascii_lower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char item) {
    return static_cast<char>(std::tolower(item));
  });
  return value;
}

bool reserved_windows_name(const std::string& segment) {
  auto base = ascii_lower(segment.substr(0, segment.find('.')));
  static const std::set<std::string> names = {
      "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5",
      "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4",
      "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"};
  return names.count(base) != 0;
}

void validate_archive_path(const std::string& path) {
  if (path.empty() || path.size() > 4096 || path.front() == '/' ||
      path.find('\\') != std::string::npos || path.find('\0') != std::string::npos) {
    throw archive_error("Unsafe NTA entry path: " + path);
  }
  std::size_t start = 0;
  while (start <= path.size()) {
    const auto end = path.find('/', start);
    const auto segment = path.substr(start, end == std::string::npos ? end : end - start);
    if (segment.empty() || segment == "." || segment == ".." ||
        segment.back() == '.' || segment.back() == ' ' ||
        segment.find_first_of(":*?\"<>|") != std::string::npos ||
        reserved_windows_name(segment)) {
      throw archive_error("Unsafe NTA entry path: " + path);
    }
    for (const auto byte : segment) {
      if (static_cast<unsigned char>(byte) < 32U) {
        throw archive_error("Unsafe NTA entry path: " + path);
      }
    }
    if (end == std::string::npos) break;
    start = end + 1;
  }
}

std::string parent_path(const std::string& value) {
  const auto separator = value.rfind('/');
  return separator == std::string::npos ? std::string() : value.substr(0, separator);
}

std::string random_suffix() {
  std::random_device source;
  std::ostringstream output;
  output << std::hex << source() << source();
  return output.str();
}

}  // namespace

nta_v2_reader nta_v2_reader::open(const fs::path& archive_path,
                                  extraction_limits limits) {
  if (limits.max_entries == 0 || limits.max_manifest_bytes == 0) {
    throw archive_error("Archive limits must be positive.");
  }
  std::ifstream input(archive_path, std::ios::binary);
  if (!input) throw archive_error("Cannot open NTA archive.");
  input.seekg(0, std::ios::end);
  const auto file_end = input.tellg();
  if (file_end < static_cast<std::streamoff>(k_preamble_length)) {
    throw archive_error("NTA archive is shorter than its preamble.");
  }
  const auto file_size = static_cast<std::uint64_t>(file_end);
  input.seekg(0, std::ios::beg);

  std::array<unsigned char, k_preamble_length> preamble{};
  read_exact(input, preamble.data(), preamble.size(), "NTA preamble");
  if (!std::equal(k_magic.begin(), k_magic.end(), preamble.begin()) ||
      be16(preamble.data() + 8) != 2) {
    throw archive_error("Unsupported or corrupt NTA V2 preamble.");
  }
  const auto flags = be16(preamble.data() + 10);
  if (flags != 0) throw archive_error("Only unencrypted NTA V2 is supported.");
  const auto public_length = be32(preamble.data() + 12);
  const auto body_length = be64(preamble.data() + 16);
  if (public_length == 0 || public_length > k_max_public_header_length ||
      body_length > limits.max_stored_body_bytes ||
      body_length > std::numeric_limits<std::uint64_t>::max() -
                        k_preamble_length - public_length ||
      file_size != k_preamble_length + public_length + body_length) {
    throw archive_error("NTA envelope lengths are invalid.");
  }

  const auto public_bytes = read_bytes(input, public_length, "NTA public header");
  json public_header;
  try {
    public_header = json::parse(public_bytes.begin(), public_bytes.end());
  } catch (const json::exception&) {
    throw archive_error("NTA public header is not valid UTF-8 JSON.");
  }
  if (!public_header.is_object() || public_header.value("format", "") != "NTA" ||
      public_header.value("version", 0) != 2 ||
      !public_header.contains("encryption") ||
      !public_header["encryption"].is_object() ||
      public_header["encryption"].value("algorithm", "") != "none") {
    throw archive_error("NTA public header identity or encryption is invalid.");
  }

  std::array<unsigned char, 8> manifest_length_bytes{};
  read_exact(input, manifest_length_bytes.data(), manifest_length_bytes.size(),
             "NTA manifest length");
  const auto manifest_length = be64(manifest_length_bytes.data());
  if (manifest_length == 0 || manifest_length > limits.max_manifest_bytes ||
      manifest_length > body_length - 8 ||
      manifest_length > static_cast<std::uint64_t>(std::numeric_limits<std::size_t>::max())) {
    throw archive_error("NTA manifest length is invalid.");
  }
  const auto manifest_bytes = read_bytes(
      input, static_cast<std::size_t>(manifest_length), "NTA manifest");
  json manifest;
  try {
    manifest = json::parse(manifest_bytes.begin(), manifest_bytes.end());
  } catch (const json::exception&) {
    throw archive_error("NTA manifest is not valid UTF-8 JSON.");
  }
  if (!manifest.is_object() || manifest.value("format", "") != "NTA" ||
      manifest.value("version", 0) != 2 || !manifest.contains("entries") ||
      !manifest["entries"].is_array() ||
      manifest["entries"].size() > limits.max_entries) {
    throw archive_error("NTA manifest identity or entry list is invalid.");
  }

  nta_v2_reader result;
  result.archive_path_ = fs::absolute(archive_path);
  result.limits_ = limits;
  result.body_offset_ = k_preamble_length + public_length;
  result.payload_offset_ = result.body_offset_ + 8 + manifest_length;

  std::unordered_map<std::string, entry_type> types;
  std::set<std::string> portable_paths;
  std::uint64_t total_size = 0;
  for (const auto& raw : manifest["entries"]) {
    if (!raw.is_object() || !raw.contains("path") || !raw["path"].is_string() ||
        !raw.contains("type") || !raw["type"].is_string() ||
        !raw.contains("size") || !raw.contains("criticalMetadata") ||
        !raw["criticalMetadata"].is_array() || !raw.contains("platformMetadata") ||
        !raw["platformMetadata"].is_object()) {
      throw archive_error("NTA entry has invalid required fields.");
    }
    entry_info entry{};
    entry.path = raw["path"].get<std::string>();
    validate_archive_path(entry.path);
    if (!portable_paths.insert(ascii_lower(entry.path)).second) {
      throw archive_error("Duplicate or Windows-aliased NTA path: " + entry.path);
    }
    const auto type_name = raw["type"].get<std::string>();
    if (type_name == "file") entry.type = entry_type::file;
    else if (type_name == "directory") entry.type = entry_type::directory;
    else if (type_name == "symbolicLink") entry.type = entry_type::symbolic_link;
    else throw archive_error("Unsupported NTA entry type: " + type_name);
    entry.size = unsigned_integer(raw["size"], "size");
    if (entry.type != entry_type::file && entry.size != 0) {
      throw archive_error("Non-file NTA entry has a nonzero size: " + entry.path);
    }
    for (const auto& critical : raw["criticalMetadata"]) {
      if (!critical.is_string()) throw archive_error("Invalid critical metadata.");
      entry.critical_metadata.push_back(critical.get<std::string>());
    }
    if (!entry.critical_metadata.empty()) {
      throw archive_error("Unsupported critical NTA metadata on " + entry.path);
    }
    if (entry.type == entry_type::symbolic_link) {
      throw archive_error("Symbolic links are not supported by this native profile.");
    }
    if (entry.type == entry_type::file) {
      if (!raw.contains("sha256") || !raw["sha256"].is_string() ||
          !raw.contains("compression") || !raw["compression"].is_string() ||
          !raw.contains("dataOffset") || !raw.contains("storedSize")) {
        throw archive_error("NTA file payload metadata is incomplete.");
      }
      entry.sha256 = raw["sha256"].get<std::string>();
      if (entry.sha256.size() != 64 ||
          !std::all_of(entry.sha256.begin(), entry.sha256.end(), [](unsigned char item) {
            return std::isdigit(item) || (item >= 'a' && item <= 'f');
          })) {
        throw archive_error("NTA file SHA-256 is invalid.");
      }
      const auto compression_name = raw["compression"].get<std::string>();
      if (compression_name == "none") entry.compression_method = compression::none;
      else if (compression_name == "zlib") entry.compression_method = compression::zlib;
      else throw archive_error("Unsupported NTA compression algorithm.");
      entry.data_offset = unsigned_integer(raw["dataOffset"], "dataOffset");
      entry.stored_size = unsigned_integer(raw["storedSize"], "storedSize");
      if (entry.size > limits.max_entry_uncompressed_bytes ||
          total_size > limits.max_total_uncompressed_bytes - entry.size) {
        throw archive_error("NTA expanded-size limit exceeded.");
      }
      total_size += entry.size;
    }
    types.emplace(entry.path, entry.type);
    result.entries_.push_back(std::move(entry));
  }

  for (const auto& entry : result.entries_) {
    const auto parent = parent_path(entry.path);
    if (!parent.empty()) {
      const auto found = types.find(parent);
      if (found == types.end() || found->second != entry_type::directory) {
        throw archive_error("NTA entry parent is absent or not a directory: " + entry.path);
      }
    }
  }
  std::vector<const entry_info*> files;
  for (const auto& entry : result.entries_) {
    if (entry.type == entry_type::file) files.push_back(&entry);
  }
  std::sort(files.begin(), files.end(), [](const auto* left, const auto* right) {
    return left->data_offset < right->data_offset;
  });
  std::uint64_t expected_offset = 0;
  for (const auto* entry : files) {
    if (entry->data_offset != expected_offset ||
        entry->stored_size > std::numeric_limits<std::uint64_t>::max() - expected_offset) {
      throw archive_error("NTA payload ranges overlap or contain gaps.");
    }
    expected_offset += entry->stored_size;
  }
  if (expected_offset != body_length - 8 - manifest_length) {
    throw archive_error("NTA payload length does not match the manifest.");
  }
  return result;
}

namespace {

void write_output(std::ofstream& output, sha256& digest,
                  const unsigned char* data, std::size_t size,
                  std::uint64_t expected_size, std::uint64_t& written) {
  if (size > expected_size - written) {
    throw archive_error("Expanded NTA file exceeds its declared size.");
  }
  output.write(reinterpret_cast<const char*>(data),
               static_cast<std::streamsize>(size));
  if (!output) throw archive_error("Failed to write extracted NTA file.");
  digest.update(data, size);
  written += size;
}

void extract_regular_file(const fs::path& archive_path,
                          std::uint64_t absolute_payload_offset,
                          const entry_info& entry,
                          const fs::path& target) {
  std::ifstream input(archive_path, std::ios::binary);
  if (!input) throw archive_error("Cannot reopen NTA archive for extraction.");
  if (absolute_payload_offset >
      static_cast<std::uint64_t>(std::numeric_limits<std::streamoff>::max())) {
    throw archive_error("NTA payload offset is not representable.");
  }
  input.seekg(static_cast<std::streamoff>(absolute_payload_offset), std::ios::beg);
  if (!input) throw archive_error("Cannot seek to NTA payload.");
  std::ofstream output(target, std::ios::binary | std::ios::trunc);
  if (!output) throw archive_error("Cannot create extracted NTA file.");
  std::vector<unsigned char> input_buffer(k_io_chunk);
  std::vector<unsigned char> output_buffer(k_io_chunk);
  sha256 digest;
  std::uint64_t remaining = entry.stored_size;
  std::uint64_t written = 0;

  if (entry.compression_method == compression::none) {
    while (remaining > 0) {
      const auto count = static_cast<std::size_t>(
          std::min<std::uint64_t>(remaining, input_buffer.size()));
      read_exact(input, input_buffer.data(), count, "NTA file payload");
      write_output(output, digest, input_buffer.data(), count, entry.size, written);
      remaining -= count;
    }
  } else {
    z_stream stream{};
    if (inflateInit(&stream) != Z_OK) {
      throw archive_error("Cannot initialize zlib decompression.");
    }
    bool ended = false;
    try {
      while (remaining > 0 && !ended) {
        const auto count = static_cast<std::size_t>(
            std::min<std::uint64_t>(remaining, input_buffer.size()));
        read_exact(input, input_buffer.data(), count, "compressed NTA payload");
        remaining -= count;
        stream.next_in = input_buffer.data();
        stream.avail_in = static_cast<uInt>(count);
        do {
          stream.next_out = output_buffer.data();
          stream.avail_out = static_cast<uInt>(output_buffer.size());
          const auto status = inflate(&stream, Z_NO_FLUSH);
          if (status != Z_OK && status != Z_STREAM_END) {
            throw archive_error("NTA zlib payload is corrupt or truncated.");
          }
          const auto produced = output_buffer.size() - stream.avail_out;
          write_output(output, digest, output_buffer.data(), produced,
                       entry.size, written);
          if (status == Z_STREAM_END) {
            ended = true;
            if (stream.avail_in != 0 || remaining != 0) {
              throw archive_error("NTA zlib payload contains trailing bytes.");
            }
            break;
          }
        } while (stream.avail_in > 0 || stream.avail_out == 0);
      }
      if (!ended) throw archive_error("NTA zlib payload is truncated.");
    } catch (...) {
      inflateEnd(&stream);
      throw;
    }
    inflateEnd(&stream);
  }
  output.close();
  if (!output || written != entry.size) {
    throw archive_error("Extracted NTA file size does not match its manifest.");
  }
  if (digest.finish_hex() != entry.sha256) {
    throw archive_error("Extracted NTA file SHA-256 does not match its manifest: " +
                        entry.path);
  }
}

}  // namespace

void nta_v2_reader::extract_to(const fs::path& destination) const {
  std::error_code status_error;
  if (fs::exists(destination, status_error) || status_error) {
    throw archive_error("NTA extraction destination already exists or is inaccessible.");
  }
  const auto parent = fs::absolute(destination).parent_path();
  if (parent.empty()) throw archive_error("NTA extraction destination has no parent.");
  fs::create_directories(parent);
  const auto staging = parent /
      ("." + destination.filename().string() + ".remvibe-staging-" + random_suffix());
  if (!fs::create_directory(staging)) {
    throw archive_error("Cannot create NTA extraction staging directory.");
  }
  try {
    std::vector<const entry_info*> directories;
    std::vector<const entry_info*> files;
    for (const auto& entry : entries_) {
      if (entry.type == entry_type::directory) directories.push_back(&entry);
      else if (entry.type == entry_type::file) files.push_back(&entry);
      else throw archive_error("Native extraction refuses symbolic links.");
    }
    std::sort(directories.begin(), directories.end(), [](const auto* left,
                                                          const auto* right) {
      return left->path.size() < right->path.size();
    });
    for (const auto* entry : directories) {
      const auto target = staging / fs::u8path(entry->path);
      if (!fs::create_directory(target)) {
        throw archive_error("Cannot create NTA directory: " + entry->path);
      }
    }
    for (const auto* entry : files) {
      const auto target = staging / fs::u8path(entry->path);
      if (!fs::is_directory(target.parent_path())) {
        throw archive_error("NTA file parent is not a real directory: " + entry->path);
      }
      std::error_code collision_error;
      if (fs::exists(target, collision_error) || collision_error) {
        throw archive_error("Target filesystem aliases NTA path: " + entry->path);
      }
      extract_regular_file(archive_path_, payload_offset_ + entry->data_offset,
                           *entry, target);
    }
    fs::rename(staging, destination);
  } catch (...) {
    std::error_code cleanup_error;
    fs::remove_all(staging, cleanup_error);
    throw;
  }
}

std::string sha256_file_hex(const fs::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw archive_error("Cannot open file for SHA-256: " + path.string());
  std::vector<unsigned char> buffer(k_io_chunk);
  sha256 digest;
  while (input) {
    input.read(reinterpret_cast<char*>(buffer.data()),
               static_cast<std::streamsize>(buffer.size()));
    const auto count = input.gcount();
    if (count > 0) digest.update(buffer.data(), static_cast<std::size_t>(count));
  }
  if (!input.eof()) throw archive_error("Failed while hashing file: " + path.string());
  return digest.finish_hex();
}

}  // namespace remvibe::archive
