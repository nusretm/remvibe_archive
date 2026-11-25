#ifndef REMVIBE_ARCHIVE_H
#define REMVIBE_ARCHIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RemVibeArchiveBuffer RemVibeArchiveBuffer;

/* ABI v1. Input UTF-8 JSON is borrowed for the call. Every non-NULL
 * result is Rust-owned; data/len are borrowed until buffer_free.
 * Call buffer_free exactly once. NULL means no result could be allocated.
 * JSON envelope: {"ok":true,"value":...} or {"ok":false,"error":...}. */
uint32_t remvibe_archive_abi_version(void);
const uint8_t *remvibe_archive_buffer_data(const RemVibeArchiveBuffer *buffer);
size_t remvibe_archive_buffer_len(const RemVibeArchiveBuffer *buffer);
void remvibe_archive_buffer_free(RemVibeArchiveBuffer *buffer);

/* Lexical path diagnostic. No disk operations. */
RemVibeArchiveBuffer *remvibe_archive_native_path_roundtrip(const uint8_t *data, size_t len);

/* Start returns a decimal-string operation handle.
 * recv blocks and returns ordered progress events, then one terminal
 * event with nested result envelope.
 * cancel requests cancellation; close releases handle and joins worker.
 * Neither holds the registry lock while waiting. */
RemVibeArchiveBuffer *remvibe_archive_core_info(void);
RemVibeArchiveBuffer *remvibe_archive_operation_recv(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_operation_cancel(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_operation_close(const uint8_t *data, size_t len);

/* Writer create/commands start native operations. The create terminal value
 * contains a distinct writer handle. One command at a time per writer.
 * Failed core add/finish closes staging; finish/abort consume the writer.
 * writer_close is idempotent, synchronous (may block) and explicitly aborts
 * unpublished staging. Always receive operation results and close handles. */
RemVibeArchiveBuffer *remvibe_archive_writer_create(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_writer_add_file(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_writer_add_directory(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_writer_finish(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_writer_abort(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_writer_close(const uint8_t *data, size_t len);

/* Reader open starts an operation; terminal contains a distinct Reader handle,
 * region and entry count. Manifest, verify and extract are asynchronous
 * operations. Optional extract index selects one regular file only.
 * Cancelled Reader must be closed and reopened. Close waits for active work. */
RemVibeArchiveBuffer *remvibe_archive_reader_open(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_reader_manifest(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_reader_verify(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_reader_extract(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_reader_close(const uint8_t *data, size_t len);

/* Selected regular-file stream. Start returns an operation handle; use
 * stream_recv (single receiver, one request at a time), not operation_recv.
 * Returned buffer starts with tag 0 (JSON envelope incl progress/terminal)
 * or 1 (raw nonempty payload, max 256 KiB). The next recv acknowledges
 * the preceding payload and grants one credit. Cancel/close use existing
 * operation functions and wake blocked producers. Payload is provisional
 * until successful terminal SHA-256 verification. Free every buffer. */
RemVibeArchiveBuffer *remvibe_archive_reader_read_entry(const uint8_t *data, size_t len);
RemVibeArchiveBuffer *remvibe_archive_stream_recv(const uint8_t *data, size_t len);

#ifdef __cplusplus
}
#endif
#endif
