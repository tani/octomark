#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define OCTOMARK_NO_MAIN
#include "octomark.c"

int main() {
  printf("--- OctoMark C Performance Benchmark & O(N) Verification ---\n");

  const char *l1 = "# Title for testing purposes\n";
  const char *l2 = "- Item list with some **bold** and `code` text\n";
  const char *l3 =
      "Regular paragraph line that should be parsed as p tags correctly.\n";

  size_t len1 = strlen(l1);
  size_t len2 = strlen(l2);
  size_t len3 = strlen(l3);
  size_t block_len = len1 + len2 + len3;

  // Test sizes in roughly MB: 10, 50, 100, 200
  long sizes_mb[] = {10, 50, 100, 200};
  int num_sizes = 4;

  for (int s = 0; s < num_sizes; s++) {
      long target_mb = sizes_mb[s];
      size_t target_bytes = target_mb * 1024 * 1024;
      int iterations = target_bytes / block_len;
      size_t total_size = iterations * block_len;

      char *data = (char *)malloc(total_size + 1);
      char *p = data;
      for (int i = 0; i < iterations; i++) {
        memcpy(p, l1, len1); p += len1;
        memcpy(p, l2, len2); p += len2;
        memcpy(p, l3, len3); p += len3;
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
      double gb_s = (total_size / (1024.0 * 1024.0 * 1024.0)) / (elapsed_ms / 1000.0);

      printf("Size: %3ld MB | Time: %7.2f ms | Throughput: %.2f GB/s\n", target_mb, elapsed_ms, gb_s);

      free(data);
      string_buffer_free(&out);
      octomark_free(&parser);
  }

  return 0;
}