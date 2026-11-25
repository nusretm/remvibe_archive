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

#ifdef __cplusplus
}
#endif
#endif
