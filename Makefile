CC ?= gcc
CFLAGS ?= -O3 -std=c99

.PHONY: all octomark benchmark test clean

all: octomark octomark_benchmark octomark_test

octomark: src/octomark.c
	$(CC) $(CFLAGS) src/octomark.c -o octomark

octomark_benchmark: benchmark/octomark_benchmark.c src/octomark.c
	$(CC) $(CFLAGS) benchmark/octomark_benchmark.c -o octomark_benchmark

octomark_test: test/octomark_test.c test/test_framework.c src/octomark.c
	$(CC) $(CFLAGS) test/octomark_test.c test/test_framework.c -o octomark_test

clean:
	rm -f octomark octomark_benchmark octomark_test
