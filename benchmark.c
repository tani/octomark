#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define OCTOMARK_NO_MAIN
#include "octomark.c"

int main() {
  printf("--- OctoMark C Performance Benchmark ---\n");

  // 1. Generate 100MB of data
  printf("Generating 100MB of data...\n");
  const char *l1 = "# Title for testing purposes\n";
  const char *l2 = "- Item list with some **bold** and `code` text\n";
  const char *l3 =
      "Regular paragraph line that should be parsed as p tags correctly.\n";

  size_t len1 = strlen(l1);
  size_t len2 = strlen(l2);
  size_t len3 = strlen(l3);
  size_t block_len = len1 + len2 + len3;

  int iterations = 750000;
  size_t total_size = iterations * block_len;

  char *data = (char *)malloc(total_size + 1);
  char *p = data;
  for (int i = 0; i < iterations; i++) {
    memcpy(p, l1, len1);
    p += len1;
    memcpy(p, l2, len2);
    p += len2;
    memcpy(p, l3, len3);
    p += len3;
  }
  *p = '\0';

  // 2. Setup
  OctomarkParser parser;
  StringBuffer out;
  string_buffer_init(&out, 1024 * 1024 * 128); // Reserve 128MB

  octomark_init(&parser);

  printf("Starting parsing of %.2f MB...\n", total_size / (1024.0 * 1024.0));

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
  double gb = total_size / (1024.0 * 1024.0 * 1024.0);
  double gb_s = gb / (elapsed_ms / 1000.0);

  printf("------------------------------------------\n");
  printf("Time:       %.2f ms\n", elapsed_ms);
  printf("Throughput: %.2f GB/s\n", gb_s);
  printf("------------------------------------------\n");

  free(data);
  string_buffer_free(&out);
  octomark_free(&parser);

  return 0;
}