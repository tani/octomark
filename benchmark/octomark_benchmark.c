#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define OCTOMARK_NO_MAIN
#include "../src/octomark.c"

int main() {
  printf("--- OctoMark C Performance Benchmark & O(N) Verification ---\n");

  const char *input_path = "EXAMPLE.md";
  FILE *input = fopen(input_path, "rb");
  if (!input) {
    fprintf(stderr, "Failed to open %s\n", input_path);
    return 1;
  }
  if (fseek(input, 0, SEEK_END) != 0) {
    fprintf(stderr, "Failed to seek %s\n", input_path);
    fclose(input);
    return 1;
  }
  long input_size = ftell(input);
  if (input_size <= 0) {
    fprintf(stderr, "Empty or invalid %s\n", input_path);
    fclose(input);
    return 1;
  }
  if (fseek(input, 0, SEEK_SET) != 0) {
    fprintf(stderr, "Failed to rewind %s\n", input_path);
    fclose(input);
    return 1;
  }

  char *block = (char *)malloc((size_t)input_size);
  if (!block) {
    fprintf(stderr, "Failed to allocate input buffer\n");
    fclose(input);
    return 1;
  }
  size_t read_bytes = fread(block, 1, (size_t)input_size, input);
  fclose(input);
  if (read_bytes != (size_t)input_size) {
    fprintf(stderr, "Failed to read %s\n", input_path);
    free(block);
    return 1;
  }
  size_t block_len = (size_t)input_size;

  // Test sizes in roughly MB: 10, 50, 100, 200
  long sizes_mb[] = {10, 50, 100, 200};
  int num_sizes = 4;

  for (int s = 0; s < num_sizes; s++) {
    long target_mb = sizes_mb[s];
    size_t target_bytes = (size_t)target_mb * 1024 * 1024;
    size_t iterations = target_bytes / block_len;
    if (iterations == 0)
      iterations = 1;
    size_t total_size = iterations * block_len;

    char *data = (char *)malloc(total_size + 1);
    if (!data) {
      fprintf(stderr, "Failed to allocate %zu bytes\n", total_size + 1);
      free(block);
      return 1;
    }
    char *p = data;
    for (size_t i = 0; i < iterations; i++) {
      memcpy(p, block, block_len);
      p += block_len;
    }
    *p = '\0';

    OctomarkParser parser;
    StringBuffer out;
    string_buffer_init(&out, total_size * 2); // Pre-allocate ample space
    octomark_init(&parser);

    clock_t start = clock();

    size_t chunk_size = 64 * 1024;
    size_t pos = 0;
    while (pos < total_size) {
      size_t rem = total_size - pos;
      size_t n = (rem > chunk_size) ? chunk_size : rem;
      octomark_feed(&parser, data + pos, n, &out);
      pos += n;
    }
    octomark_finish(&parser, &out);

    clock_t end = clock();
    double elapsed_ms = (double)(end - start) / CLOCKS_PER_SEC * 1000.0;
    double gb_s = (total_size / (1024.0 * 1024.0 * 1024.0)) /
                  (elapsed_ms / 1000.0);

    printf("Size: %3ld MB | Time: %7.2f ms | Throughput: %.2f GB/s\n",
           target_mb, elapsed_ms, gb_s);

    free(data);
    string_buffer_free(&out);
    octomark_free(&parser);
  }

  free(block);
  return 0;
}
