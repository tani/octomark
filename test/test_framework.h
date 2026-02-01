#ifndef TEST_FRAMEWORK_H
#define TEST_FRAMEWORK_H

#include <stdbool.h>
#include <stddef.h>

typedef struct {
  const char *name;
  const char *input;
  const char *expected;
  bool enable_html;
} TestCase;

typedef struct {
  int passed;
  int total;
} TestSummary;

TestSummary run_octomark_tests(const TestCase *cases, size_t count);

#endif
