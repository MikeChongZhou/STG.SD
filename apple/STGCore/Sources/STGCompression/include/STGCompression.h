#include <stddef.h>

// The caller owns *output and frees it with stg_free_buffer.
int stg_archive_transform(const unsigned char *input, size_t input_length,
                          unsigned char **output, size_t *output_length,
                          int decompress, int gzip_format);
void stg_free_buffer(unsigned char *buffer);
