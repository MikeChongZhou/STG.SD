#include "STGCompression.h"
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

int stg_archive_transform(const unsigned char *input, size_t input_length,
                          unsigned char **output, size_t *output_length,
                          int decompress, int gzip_format) {
    if (!input || !output || !output_length || input_length > UINT_MAX) return Z_STREAM_ERROR;
    *output = NULL;
    *output_length = 0;
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    int status = decompress ? inflateInit2(&stream, gzip_format == 2 ? -15 : (gzip_format ? 15 + 32 : 15))
                            : deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                                           gzip_format == 2 ? -15 : (gzip_format ? 15 + 16 : 15), 8, Z_DEFAULT_STRATEGY);
    if (status != Z_OK) return status;
    size_t capacity = input_length * 2 + 1024;
    if (capacity < 4096) capacity = 4096;
    unsigned char *buffer = malloc(capacity);
    if (!buffer) { if (decompress) inflateEnd(&stream); else deflateEnd(&stream); return Z_MEM_ERROR; }
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_length;
    do {
        if (stream.total_out == capacity) {
            if (capacity > SIZE_MAX / 2 || capacity > UINT_MAX / 2) { status = Z_MEM_ERROR; break; }
            capacity *= 2;
            unsigned char *grown = realloc(buffer, capacity);
            if (!grown) { status = Z_MEM_ERROR; break; }
            buffer = grown;
        }
        stream.next_out = buffer + stream.total_out;
        stream.avail_out = (uInt)(capacity - stream.total_out);
        status = decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH);
    } while (status == Z_OK);
    if (status == Z_STREAM_END) {
        *output_length = stream.total_out;
        *output = buffer;
        buffer = NULL;
        status = Z_OK;
    }
    free(buffer);
    if (decompress) inflateEnd(&stream); else deflateEnd(&stream);
    return status;
}

void stg_free_buffer(unsigned char *buffer) { free(buffer); }
