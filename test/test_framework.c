#include "test_framework.h"

#include <stdio.h>
#include <string.h>

#define OCTOMARK_NO_MAIN
#include "../src/octomark.c"

TestSummary run_octomark_tests(const TestCase *cases, size_t count) {
  TestSummary summary = {0, (int)count};
  OctomarkParser parser;
  StringBuffer out;

  string_buffer_init(&out, 65536);

  for (size_t i = 0; i < count; i++) {
    octomark_init(&parser);
    parser.enable_html = cases[i].enable_html;
    out.size = 0;
    out.data[0] = '\0';

    octomark_feed(&parser, cases[i].input, strlen(cases[i].input), &out);
    octomark_finish(&parser, &out);

    if (strcmp(out.data, cases[i].expected) == 0) {
      summary.passed++;
    } else {
      printf("[FAIL] %s\n", cases[i].name);
      printf("Expected: [%s]\n", cases[i].expected);
      printf("Actual:   [%s]\n", out.data);
    }

    octomark_free(&parser);
  }

  string_buffer_free(&out);
  return summary;
}
